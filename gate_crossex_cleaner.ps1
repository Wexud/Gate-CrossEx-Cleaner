[CmdletBinding()]
param(
    [switch]$BalancesOnly,
    [decimal]$MaxQuoteWorseningPercent = 1.0,
    [decimal]$StablecoinMaxLossPercent = 1.0,
    [int]$MaxCandidates = 40
)

# Gate CrossEx Cleaner
# Version: 1.0.3
# Windows PowerShell 5.1 / PowerShell 7+
# Converts supported CrossEx residual assets to CROSSEX USDT and transfers USDT to Gate SPOT.
# Does NOT perform blockchain withdrawals.

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 5) { throw 'PowerShell 5.1 or newer is required.' }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$ApiHost = 'https://api.gateio.ws'
$Prefix = '/api/v4'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$SupportedVenues = @('BINANCE','OKX','GATE','BYBIT','KRAKEN','HYPERLIQUID')

function D($v,[string]$name='value') {
    if ($null -eq $v -or [string]::IsNullOrWhiteSpace([string]$v)) { return [decimal]0 }
    try { return [decimal]::Parse([Convert]::ToString($v,$Inv),[Globalization.NumberStyles]::Float,$Inv) }
    catch { throw "Gate returned invalid numeric ${name}: '$v'" }
}
function DS([decimal]$v) { $v.ToString('0.############################',$Inv) }
function Pct([decimal]$v) { $v.ToString('0.0000',$Inv) + '%' }
function UnixTime { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function Sha512([string]$s) {
    $h=[Security.Cryptography.SHA512]::Create(); try { ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)))).Replace('-','').ToLowerInvariant() } finally { $h.Dispose() }
}
function Hmac512([string]$key,[string]$s) {
    $h=New-Object Security.Cryptography.HMACSHA512; try { $h.Key=[Text.Encoding]::UTF8.GetBytes($key); ([BitConverter]::ToString($h.ComputeHash([Text.Encoding]::UTF8.GetBytes($s)))).Replace('-','').ToLowerInvariant() } finally { $h.Dispose() }
}
function HttpError($e) {
    $a=@()
    if($e.Exception.Message){$a+=$e.Exception.Message}
    if($e.ErrorDetails -and $e.ErrorDetails.Message){$a+=$e.ErrorDetails.Message}
    try {
        if($e.Exception.Response){
            $stream=$e.Exception.Response.GetResponseStream()
            if($stream){
                $reader=New-Object IO.StreamReader($stream)
                try{$body=$reader.ReadToEnd();if(-not [string]::IsNullOrWhiteSpace($body)){$a+=$body}}finally{$reader.Dispose()}
            }
        }
    } catch {}
    if(!$a.Count){'Unknown HTTP error'}else{($a|Select-Object -Unique) -join ' | '}
}
function Gate([string]$Method,[string]$Path,[string]$Query='',$Body=$null,[bool]$Signed=$true) {
    $Method=$Method.ToUpperInvariant(); $bodyText=if($null -eq $Body){''}else{$Body|ConvertTo-Json -Compress -Depth 10}
    $uri="$ApiHost$Prefix$Path"; if($Query){$uri+="?$Query"}
    $headers=@{Accept='application/json'}
    if($Signed){
        $ts=(UnixTime).ToString($Inv); $hash=Sha512 $bodyText
        $signText=$Method+"`n"+$Prefix+$Path+"`n"+$Query+"`n"+$hash+"`n"+$ts
        $headers.KEY=$script:ApiKey; $headers.Timestamp=$ts; $headers.SIGN=Hmac512 $script:ApiSecret $signText
    }
    $p=@{Method=$Method;Uri=$uri;Headers=$headers;ErrorAction='Stop'}
    if($null -ne $Body){$p.Body=$bodyText;$p.ContentType='application/json'}
    try { Invoke-RestMethod @p } catch { throw "Gate API $Method $Path failed: $(HttpError $_)" }
}

function Account { Gate GET '/crossex/accounts' }
function OpenOrders { @(Gate GET '/crossex/open_orders') }
function Asset($a,[string]$venue,[string]$coin) {
    @($a.assets)|Where-Object{([string]$_.exchange_type).ToUpperInvariant() -eq $venue.ToUpperInvariant() -and ([string]$_.coin).ToUpperInvariant() -eq $coin.ToUpperInvariant()}|Select-Object -First 1
}
function NonZero($a) { @($a.assets)|Where-Object{(D $_.balance 'balance') -ne 0 -or (D $_.available_balance 'available_balance') -ne 0} }
function ShowBalances($a) {
    $x=@(NonZero $a); Write-Host ''; Write-Host 'Current non-zero CrossEx balances:' -ForegroundColor Cyan
    if(!$x.Count){Write-Host '  No non-zero balances.';return}
    Write-Host ('{0,-15} {1,-10} {2,26} {3,26} {4,18}' -f 'ACCOUNT','COIN','BALANCE','AVAILABLE','LIABILITY'); Write-Host ('-'*100)
    foreach($i in $x){Write-Host ('{0,-15} {1,-10} {2,26} {3,26} {4,18}' -f $i.exchange_type,$i.coin,$i.balance,$i.available_balance,$i.liability)}
}
function UsdtAvailable($a) { $x=Asset $a 'CROSSEX' 'USDT'; if($null -eq $x){[decimal]0}else{D $x.available_balance 'CROSSEX USDT available_balance'} }
function RiskReasons($a) {
    $r=@(); if((D $a.initial_margin 'initial_margin') -gt 0){$r+="initial_margin=$($a.initial_margin)"}; if((D $a.maintenance_margin 'maintenance_margin') -gt 0){$r+="maintenance_margin=$($a.maintenance_margin)"}
    foreach($x in @($a.assets)){
        $n="$($x.exchange_type) $($x.coin)"
        foreach($f in @('liability','futures_initial_margin','futures_maintenance_margin','borrowing_initial_margin','borrowing_maintenance_margin')){if((D $x.$f $f) -gt 0){$r+="$f $n=$($x.$f)"}}
        if((D $x.upnl 'upnl') -ne 0){$r+="upnl $n=$($x.upnl)"}
    }; $r
}
function Candidates($a) {
    $ok=@();$skip=@()
    foreach($x in @(NonZero $a)){
        $v=([string]$x.exchange_type).ToUpperInvariant();$c=([string]$x.coin).ToUpperInvariant();$n=D $x.available_balance 'available_balance'
        if($n -le 0 -or $c -eq 'USDT'){continue}
        $reason=$null
        if($v -eq 'CROSSEX'){$reason='CROSSEX itself is not a Flash Swap venue'}
        elseif($SupportedVenues -notcontains $v){$reason='Flash Swap venue is not supported by Gate'}
        elseif($v -eq 'HYPERLIQUID' -and $c -ne 'USDC'){$reason='Gate documents HYPERLIQUID_USDC -> CROSSEX_USDT only'}
        elseif($v -eq 'KRAKEN' -and $c -ne 'USD'){$reason='Gate documents KRAKEN_USD -> CROSSEX_USDT only'}
        if($reason){$skip+=[pscustomobject]@{Asset=$x;Reason=$reason}}else{$ok+=$x}
    }
    [pscustomobject]@{Candidates=$ok;Skipped=$skip}
}
function Quote([string]$venue,[string]$coin,[decimal]$amount) {
    $q=Gate POST '/crossex/convert/quote' '' ([ordered]@{exchange_type=$venue;from_coin=$coin;to_coin='USDT';from_amount=(DS $amount)})
    if([string]::IsNullOrWhiteSpace([string]$q.quote_id)){throw 'Quote response has no quote_id'}
    if(([string]$q.to_coin).ToUpperInvariant() -ne 'USDT'){throw 'Quote target is not USDT'}
    if((D $q.from_amount 'quote.from_amount') -le 0 -or (D $q.to_amount 'quote.to_amount') -le 0){throw 'Quote returned non-positive amount'}
    $q
}
function Rate($q) { (D $q.to_amount 'quote.to_amount')/(D $q.from_amount 'quote.from_amount') }
function Worse([decimal]$a,[decimal]$b) { if($b -ge $a){[decimal]0}else{(($a-$b)/$a)*100} }
function StableLoss([decimal]$r) { if($r -ge 1){[decimal]0}else{(1-$r)*100} }
function ExecuteQuote([string]$id) { Gate POST '/crossex/convert/orders' '' ([ordered]@{quote_id=$id}) }
function GetOrder([string]$id) { Gate GET ("/crossex/orders/{0}" -f $id) }
function WaitOrder([string]$id,[int]$sec=30) {
    $last=$null; for($i=0;$i -lt $sec;$i++){
        try{$last=GetOrder $id;$s=([string]$last.state).ToUpperInvariant();if(@('FILLED','FAIL','REJECT','CANCELLED') -contains $s){return $last}}catch{}
        Start-Sleep 1
    };$last
}
function WaitSettlement([string]$venue,[string]$coin,[decimal]$srcBefore,[decimal]$usdtBefore,[int]$sec=30) {
    for($i=0;$i -lt $sec;$i++){
        Start-Sleep 1;$a=Account;$x=Asset $a $venue $coin;$src=if($null -eq $x){[decimal]0}else{D $x.available_balance 'source available_balance'};$u=UsdtAvailable $a
        if($src -lt $srcBefore -and $u -gt $usdtBefore){return [pscustomobject]@{Settled=$true;SourceNow=$src;UsdtNow=$u}}
    };[pscustomobject]@{Settled=$false}
}
function TransferRule { @(Gate GET '/crossex/transfers/coin' 'coin=USDT' $null $false)|Where-Object{([string]$_.coin).ToUpperInvariant() -eq 'USDT'}|Select-Object -First 1 }
function RoundDown([decimal]$n,[int]$p){if($p -lt 0 -or $p -gt 28){throw "Invalid precision: $p"};$f=[decimal]1;for($i=0;$i -lt $p;$i++){$f*=10};[decimal]::Floor($n*$f)/$f}
function Transfer([decimal]$n){Gate POST '/crossex/transfers' '' ([ordered]@{coin='USDT';amount=(DS $n);from='CROSSEX';to='SPOT'})}
function TransferRows([string]$id){@(Gate GET '/crossex/transfers' ("order_id={0}&limit=10" -f $id))}
function WaitTransfer([string]$id,[int]$sec=30){$last=$null;for($i=0;$i -lt $sec;$i++){foreach($r in @(TransferRows $id)){if(([string]$r.id) -eq $id){$last=$r;$s=([string]$r.status).ToUpperInvariant();if(@('SUCCESS','FAIL') -contains $s){return $r}}};Start-Sleep 1};$last}
function Yes([string]$q){((Read-Host $q).Trim() -ceq 'YES')}

try {
    Write-Host '';Write-Host 'Gate CrossEx Cleaner v1.0.3' -ForegroundColor Cyan
    Write-Host "PowerShell $($PSVersionTable.PSVersion)";Write-Host 'This script does NOT perform blockchain withdrawals.'
    if($MaxQuoteWorseningPercent -lt 0 -or $StablecoinMaxLossPercent -lt 0){throw 'Percentage limits cannot be negative'}
    if($MaxCandidates -lt 1 -or $MaxCandidates -gt 40){throw 'MaxCandidates must be 1..40'}

    $script:ApiKey=(Read-Host 'Gate CrossEx API Key').Trim();$ss=Read-Host 'Gate CrossEx API Secret (hidden)' -AsSecureString;$b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($ss)
    try{$script:ApiSecret=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($b)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b)}
    if([string]::IsNullOrWhiteSpace($script:ApiKey) -or [string]::IsNullOrWhiteSpace($script:ApiSecret)){throw 'API Key/Secret is empty'}

    $a=Account;ShowBalances $a
    if($BalancesOnly){Write-Host '';Write-Host 'Balances-only mode: no financial operations were performed.' -ForegroundColor Green;return}
    if(([string]$a.account_mode).ToUpperInvariant() -ne 'CROSS_EXCHANGE'){throw "Full cleaner requires account_mode=CROSS_EXCHANGE; got '$($a.account_mode)'"}

    $risk=@(RiskReasons $a);$oo=@(OpenOrders);if($oo.Count){$risk+="open_orders=$($oo.Count)"}
    if($risk.Count){Write-Host '';Write-Host 'STOP: active exposure/open orders detected:' -ForegroundColor Red;$risk|ForEach-Object{Write-Host "  - $_"};return}

    $cr=Candidates $a;$cand=@($cr.Candidates);$skip=@($cr.Skipped)
    if($skip.Count){Write-Host '';Write-Host 'Skipped before quote:' -ForegroundColor Yellow;foreach($s in $skip){Write-Host "  $($s.Asset.exchange_type) $($s.Asset.coin): $($s.Reason)"}}
    if($cand.Count -gt $MaxCandidates){throw "Found $($cand.Count) candidates; MaxCandidates=$MaxCandidates"}

    $pre=@()
    if($cand.Count -and (Yes 'Request preview quotes now? Type YES')){
        foreach($x in $cand){
            $v=([string]$x.exchange_type).ToUpperInvariant();$c=([string]$x.coin).ToUpperInvariant();$n=D $x.available_balance 'available_balance'
            Write-Host -NoNewline "$v $c $(DS $n) -> USDT ... "
            try{$q=Quote $v $c $n;$r=Rate $q;if(@('USDC','USD') -contains $c -and (StableLoss $r) -gt $StablecoinMaxLossPercent){Write-Host 'SKIP stablecoin loss' -ForegroundColor Yellow;continue};$pre+=[pscustomobject]@{Venue=$v;Coin=$c;Rate=$r};Write-Host "OK: $($q.to_amount) USDT" -ForegroundColor Green}catch{Write-Host "SKIP: $($_.Exception.Message)" -ForegroundColor Yellow}
        }
    }

    $amb=$false
    if($pre.Count -and (Yes 'Execute accepted Flash Swaps? Type YES')){
        foreach($p in $pre){
            $cur=Account;$x=Asset $cur $p.Venue $p.Coin;if($null -eq $x){continue};$n=D $x.available_balance 'current available_balance';if($n -le 0){continue}
            try{$q=Quote $p.Venue $p.Coin $n;$r=Rate $q}catch{Write-Host "SKIP fresh quote: $($_.Exception.Message)" -ForegroundColor Yellow;continue}
            $w=Worse $p.Rate $r;if($w -gt $MaxQuoteWorseningPercent){Write-Host "SKIP $($p.Venue) $($p.Coin): worsening $(Pct $w)" -ForegroundColor Yellow;continue}
            if(@('USDC','USD') -contains $p.Coin -and (StableLoss $r) -gt $StablecoinMaxLossPercent){Write-Host 'SKIP stablecoin loss' -ForegroundColor Yellow;continue}
            $u0=UsdtAvailable $cur
            try{$o=ExecuteQuote ([string]$q.quote_id)}catch{Write-Host "AMBIGUOUS swap POST: $($_.Exception.Message)" -ForegroundColor Red;$amb=$true;break}
            $id=[string]$o.order_id;if(!$id){Write-Host 'AMBIGUOUS: no order_id' -ForegroundColor Red;$amb=$true;break}
            Write-Host "Gate accepted Flash Swap. order_id=$id" -ForegroundColor Green
            $st=WaitOrder $id 30;if($null -eq $st){$amb=$true;break};$state=([string]$st.state).ToUpperInvariant()
            if(@('FAIL','REJECT','CANCELLED') -contains $state){Write-Host "Swap state=$state reason=$($st.reason)" -ForegroundColor Yellow;continue}
            if($state -ne 'FILLED' -or ([string]$st.business_type).ToUpperInvariant() -ne 'CONVERT'){Write-Host "AMBIGUOUS order state/type: $state/$($st.business_type)" -ForegroundColor Red;$amb=$true;break}
            $sett=WaitSettlement $p.Venue $p.Coin $n $u0 30;if(!$sett.Settled){Write-Host 'AMBIGUOUS: FILLED but balance settlement not confirmed' -ForegroundColor Red;$amb=$true;break}
            Write-Host "Settlement confirmed; CROSSEX USDT $(DS $u0) -> $(DS $sett.UsdtNow)" -ForegroundColor Green
        }
    }

    $a=Account;ShowBalances $a;if($amb){Write-Host 'STOP: ambiguous Flash Swap state. Verify Gate manually before rerun.' -ForegroundColor Red;return}
    $u=UsdtAvailable $a;if($u -le 0){Write-Host 'No CROSSEX USDT available for SPOT transfer.';return}
    $rule=TransferRule;if($null -eq $rule){throw 'No USDT transfer rule returned'};if([int]$rule.is_disabled -ne 0){Write-Host 'USDT transfer is disabled by Gate.' -ForegroundColor Yellow;return}
    $prec=[int]$rule.precision;$min=D $rule.min_trans_amount 'min_trans_amount';$fee=D $rule.est_fee 'est_fee';$base=$u;if($fee -gt 0){$base-=$fee};if($base -lt 0){$base=0};$amt=RoundDown $base $prec
    Write-Host '';Write-Host 'CROSSEX USDT -> SPOT:' -ForegroundColor Cyan;Write-Host "  available=$(DS $u)  transferable=$(DS $amt)  min=$(DS $min)  fee=$(DS $fee)  precision=$prec"
    if($amt -le 0 -or $amt -lt $min){Write-Host 'Transfer amount below minimum.';return};if(!(Yes "Transfer $(DS $amt) USDT to SPOT? Type YES")){Write-Host 'Transfer cancelled.';return}
    try{$tr=Transfer $amt}catch{Write-Host "AMBIGUOUS transfer POST: $($_.Exception.Message)" -ForegroundColor Red;return};$tid=[string]$tr.tx_id;if(!$tid){Write-Host 'AMBIGUOUS: no tx_id' -ForegroundColor Red;return}
    Write-Host "Gate accepted transfer. tx_id=$tid" -ForegroundColor Green
    try{$row=WaitTransfer $tid 30;if($null -eq $row){Write-Host 'Transfer status timeout; do not retry automatically.' -ForegroundColor Yellow}elseif(([string]$row.status).ToUpperInvariant() -eq 'SUCCESS'){Write-Host "Transfer SUCCESS. actual_receive=$($row.actual_receive) USDT" -ForegroundColor Green}else{Write-Host "Transfer FAIL: $($row.fail_reason)" -ForegroundColor Red}}catch{Write-Host "Status check failed: $($_.Exception.Message). Do not retry automatically." -ForegroundColor Yellow}
    Write-Host '';Write-Host 'Final CrossEx balances:' -ForegroundColor Cyan;ShowBalances (Account)
}
catch { Write-Host '';Write-Host "STOP: $($_.Exception.Message)" -ForegroundColor Red }
finally { $script:ApiSecret=$null;$ss=$null }
