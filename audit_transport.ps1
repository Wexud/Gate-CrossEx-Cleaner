param([string]$ScriptPath='./gate_crossex_cleaner.ps1')
$ErrorActionPreference='Stop'
$Inv=[Globalization.CultureInfo]::InvariantCulture
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Resolve-Path $ScriptPath).Path,[ref]$t,[ref]$e)
if($e.Count){throw 'Native ParseFile failed'}
foreach($f in $ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$false)){. ([scriptblock]::Create($f.Extent.Text))}
$script:ApiKey='LOCAL-TEST-KEY';$script:ApiSecret='LOCAL-TEST-SECRET';$Prefix='/api/v4'
Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
public sealed class LocalGateFixture : IDisposable {
    private TcpListener listener;
    private Thread worker;
    private volatile bool stop;
    public int Port;
    public int Requests;
    public string Body;
    public string Header;
    public string Error;
    private string json;
    private int code;
    public LocalGateFixture(string response, int status) {
        json=response; code=status;
        listener=new TcpListener(IPAddress.Loopback,0);
        listener.Start(); Port=((IPEndPoint)listener.LocalEndpoint).Port;
        worker=new Thread(Serve); worker.IsBackground=true; worker.Start();
    }
    private void Serve() {
        while(!stop) {
            try {
                using(TcpClient client=listener.AcceptTcpClient()) {
                    client.ReceiveTimeout=5000; client.SendTimeout=5000;
                    using(NetworkStream stream=client.GetStream()) {
                        StringBuilder header=new StringBuilder();
                        while(header.Length < 65536 && !header.ToString().EndsWith("\r\n\r\n")) {
                            int b=stream.ReadByte(); if(b<0) throw new Exception("Header ended early"); header.Append((char)b);
                        }
                        Header=header.ToString();
                        if(Header.IndexOf("Expect: 100-continue",StringComparison.OrdinalIgnoreCase)>=0) {
                            byte[] interim=Encoding.ASCII.GetBytes("HTTP/1.1 100 Continue\r\n\r\n"); stream.Write(interim,0,interim.Length); stream.Flush();
                        }
                        Match m=Regex.Match(Header,@"Content-Length:\s*(\d+)",RegexOptions.IgnoreCase);
                        int size=m.Success?Int32.Parse(m.Groups[1].Value):0;
                        byte[] payload=new byte[size]; int offset=0;
                        while(offset<size) { int n=stream.Read(payload,offset,size-offset); if(n==0)throw new Exception("Body ended early"); offset+=n; }
                        Body=Encoding.UTF8.GetString(payload);
                        Interlocked.Increment(ref Requests);
                        byte[] bytes=Encoding.UTF8.GetBytes(json);
                        string location=code==302?"Location: http://127.0.0.1:"+Port+"/redirect-target\r\n":"";
                        byte[] response=Encoding.ASCII.GetBytes("HTTP/1.1 "+code+" Test\r\nContent-Type: application/json\r\nContent-Length: "+bytes.Length+"\r\n"+location+"Connection: close\r\n\r\n");
                        stream.Write(response,0,response.Length); stream.Write(bytes,0,bytes.Length); stream.Flush();
                    }
                }
            } catch(Exception ex) { if(!stop) Error=ex.Message; }
        }
    }
    public void Dispose() { stop=true; listener.Stop(); if(worker!=null)worker.Join(6000); }
}
'@
function Must([bool]$condition,[string]$message){if(-not $condition){throw $message}}
$passed=0
foreach($case in @(
    @{name='empty array';json='[]';count=0},
    @{name='single row array';json='[{"id":"1"}]';count=1},
    @{name='two row array';json='[{"id":"1"},{"id":"2"}]';count=2}
)){
    $server=New-Object LocalGateFixture($case.json,200)
    try{
        $ApiHost='http://127.0.0.1:'+ $server.Port
        $rows=List '/crossex/open_orders'
        Must ($rows -is [array]) 'Root array lost by real Invoke-RestMethod'
        Must ($rows.Count -eq $case.count) 'Wrong number of native HTTP rows'
        Must ($server.Requests -eq 1) 'Unexpected native HTTP retries'
        Write-Host "PASS native HTTP: $($case.name)";$passed++
    }finally{$server.Dispose()}
}
$server=New-Object LocalGateFixture('{"order_id":"123456789012345678"}',200)
try{
    $ApiHost='http://127.0.0.1:'+ $server.Port
    $reply=Gate 'POST' '/crossex/convert/orders' '' ([ordered]@{quote_id='dummy-quote'})
    Must ($server.Body -ceq '{"quote_id":"dummy-quote"}') 'POST bytes differ from signed JSON'
    Must ($reply.order_id -ceq '123456789012345678') 'String ID damaged by native parser'
    Must ($server.Header -match 'Timestamp: [0-9]+') 'Timestamp missing'
    Must ($server.Header -match 'SIGN: [0-9a-f]{128}') 'HMAC header missing'
    Must ($server.Requests -eq 1) 'Duplicate native POST'
    Write-Host 'PASS native HTTP: signed POST bytes and large string ID';$passed++
}finally{$server.Dispose()}
foreach($status in @(403,503)){
    $server=New-Object LocalGateFixture('{"label":"LOCAL_FIXTURE_ERROR","message":"LOCAL-TEST-SECRET"}',$status)
    try{
        $ApiHost='http://127.0.0.1:'+ $server.Port
        $errorCaught=$null
        try{$null=Gate 'POST' '/crossex/convert/orders' '' ([ordered]@{quote_id='dummy-quote'})}catch{$errorCaught=$_}
        Must ($null -ne $errorCaught) 'HTTP failure swallowed'
        Must ($errorCaught.Exception.Message -notlike '*LOCAL-TEST-SECRET*') 'Secret leaked in error'
        Must ($errorCaught.Exception.Data['GateLabel'] -eq 'LOCAL_FIXTURE_ERROR') 'Native HTTP error body lost'
        Must ($server.Requests -eq 1) 'POST retried after native HTTP failure'
        Write-Host "PASS native HTTP: $status body extraction, redaction and no retry";$passed++
    }finally{$server.Dispose()}
}
$server=New-Object LocalGateFixture('{}',302)
try{
    $ApiHost='http://127.0.0.1:'+ $server.Port
    $caught=$false
    try{$null=Gate 'POST' '/crossex/convert/orders' '' ([ordered]@{quote_id='dummy-quote'})}catch{$caught=$true}
    Must $caught 'Redirect did not stop execution'
    Must ($server.Requests -eq 1) 'Client followed a redirect with credentials'
    Write-Host 'PASS native HTTP: redirect not followed';$passed++
}finally{$server.Dispose()}
Write-Host "TRANSPORT RESULT: $passed passed. Native Invoke-RestMethod, loopback only; no connection to Gate."
