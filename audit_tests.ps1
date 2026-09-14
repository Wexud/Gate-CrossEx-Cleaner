param([string]$ScriptPath = './gate_crossex_cleaner.ps1')
$ErrorActionPreference = 'Stop'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$Source = [IO.File]::ReadAllText((Resolve-Path $ScriptPath).Path)
$Tokens = $null; $Errors = $null
$Ast = [System.Management.Automation.Language.Parser]::ParseInput($Source,[ref]$Tokens,[ref]$Errors)
if ($Errors.Count) { $Errors | Format-List *; throw 'Syntax failure' }
$Hash = [Security.Cryptography.SHA256]::Create()
try { [Console]::WriteLine('SOURCE SHA256 (LF): '+([BitConverter]::ToString($Hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Source.Replace("`r`n","`n"))))).Replace('-','').ToLowerInvariant()) } finally { $Hash.Dispose() }
$Functions = $Ast.FindAll({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst]},$false)
foreach ($Fn in $Functions) { . ([scriptblock]::Create($Fn.Extent.Text)) }
$script:RealUtc = (Get-Command UnixTime).ScriptBlock
$script:RealWaitSettlement = (Get-Command WaitSettlement).ScriptBlock
$script:RealWaitTransfer = (Get-Command WaitTransfer).ScriptBlock
function UnixTime { return [int64]1541993715 }
function WaitSettlement($Before,$Venue,$Coin,$QuoteData,[int]$Seconds=30) { return & $script:RealWaitSettlement $Before $Venue $Coin $QuoteData 1 }
function WaitTransfer($TxId,[decimal]$Amount,[int]$Seconds=30) { return & $script:RealWaitTransfer $TxId $Amount 1 }
function Start-Sleep { param([int]$Milliseconds,[int]$Seconds) [Threading.Thread]::Sleep(5) }
function Write-Host { param([Parameter(Position=0,ValueFromRemainingArguments=$true)]$Object,[switch]$NoNewline,$ForegroundColor) $null = $script:Output.Add(($Object -join ' ')) }
function Assert([bool]$Condition,[string]$Message='Assertion failed') { if (-not $Condition) { throw $Message } }
function Equal($Actual,$Expected) { if ($Actual -cne $Expected) { throw "Expected '$Expected', got '$Actual'." } }
function Throws([scriptblock]$Body,[string]$Pattern='*') {
    try { & $Body | Out-Null } catch { if ($_.Exception.Message -notlike $Pattern) { throw "Unexpected exception: $($_.Exception.Message)" }; return }
    throw 'Expected an exception, but operation was accepted.'
}
function CloneMock($Object) { return ($Object | ConvertTo-Json -Depth 20 | ConvertFrom-Json) }
function MakeAsset([string]$Venue,[string]$Coin,[string]$Amount) {
    return [pscustomobject]@{exchange_type=$Venue;coin=$Coin;balance=$Amount;available_balance=$Amount;liability='0';upnl='0';futures_initial_margin='0';futures_maintenance_margin='0';borrowing_initial_margin='0';borrowing_maintenance_margin='0'}
}
function Reset([string]$Scenario='normal') {
    $script:Scenario=$Scenario; $script:ApprovedSwap=$false; $script:ApprovedTransfer=$false
    $script:ApiKey='OFFLINE-TEST-KEY'; $script:ApiSecret='OFFLINE-TEST-SECRET'; $script:QuoteRequests=0; $script:PendingOperation=$null
    $script:Calls=New-Object Collections.ArrayList; $script:Output=New-Object Collections.ArrayList
    $script:Answers=New-Object Collections.Queue; @('YES','YES','YES') | ForEach-Object { $script:Answers.Enqueue($_) }
    $script:Quotes=@{}; $script:Qn=0; $script:HistoryCount=0; $script:LastTransfer=$null; $script:LastRequest=$null
    $script:Data=[pscustomobject]@{user_id='offline-user';account_mode='CROSS_EXCHANGE';initial_margin='0';maintenance_margin='0';assets=@((MakeAsset 'HYPERLIQUID' 'USDC' '12.23696671'),(MakeAsset 'CROSSEX' 'USDT' '0'))}
    $script:Rule=[pscustomobject]@{coin='USDT';min_trans_amount=0.00000001;est_fee=0;precision=8;is_disabled=0}
    $script:Futures=@(); $script:Margins=@(); $script:Orders=@()
    $script:MaxCandidates=40; $script:MaxQuoteWorseningPercent=[decimal]1; $script:StablecoinMaxLossPercent=[decimal]1
    $script:ApiHost='https://api.gateio.ws'; $script:Prefix='/api/v4'; $script:SupportedVenues=@('BINANCE','OKX','GATE','BYBIT','KRAKEN','HYPERLIQUID')
}
function CountCalls([string]$Method,[string]$Path) { return @($script:Calls | Where-Object { $_.Method -eq $Method -and $_.Path -eq $Path }).Count }
function NoWrites { Equal (CountCalls 'POST' '/crossex/convert/orders') 0; Equal (CountCalls 'POST' '/crossex/transfers') 0 }
function OnlyUsdt([string]$Amount='12.21616386000000000194') { $script:Data.assets=@((MakeAsset 'CROSSEX' 'USDT' $Amount)) }
function Read-Host {
    param([string]$Prompt,[switch]$AsSecureString)
    if ($Prompt -eq 'Gate CrossEx API Key') { return 'OFFLINE-TEST-KEY' }
    if ($AsSecureString) { return ConvertTo-SecureString 'OFFLINE-TEST-SECRET' -AsPlainText -Force }
    if ($Prompt -like 'Execute accepted*') {
        $script:ApprovedSwap=$true
        if ($script:Scenario -eq 'source-increase') { $script:Data.assets[0].available_balance='15'; $script:Data.assets[0].balance='15' }
        if ($script:Scenario -eq 'source-decrease') { $script:Data.assets[0].available_balance='10'; $script:Data.assets[0].balance='10' }
        if ($script:Scenario -eq 'new-order') { $script:Orders=@([pscustomobject]@{order_id='9'}) }
        if ($script:Scenario -eq 'new-future') { $script:Futures=@([pscustomobject]@{position_qty='1';initial_margin='0';maintenance_margin='0';upnl='0'}) }
    }
    if ($Prompt -like 'Transfer *Type YES') {
        $script:ApprovedTransfer=$true
        if ($script:Scenario -eq 'transfer-balance-change') { $u=Asset $script:Data 'CROSSEX' 'USDT'; $u.available_balance='7'; $u.balance='7' }
        if ($script:Scenario -eq 'fee-change') { $script:Rule.est_fee=1 }
        if ($script:Scenario -eq 'precision-change') { $script:Rule.precision=5 }
        if ($script:Scenario -eq 'minimum-change') { $script:Rule.min_trans_amount=1 }
        if ($script:Scenario -eq 'new-margin') { $script:Margins=@([pscustomobject]@{asset_qty='0';liability='1';interest='0';initial_margin='0';maintenance_margin='0';upnl='0'}) }
    }
    if ($script:Answers.Count -eq 0) { throw "Unconfigured prompt: $Prompt" }
    return $script:Answers.Dequeue()
}
function ApiError([string]$Label) {
    $e=New-Object Net.WebException('Simulated HTTP failure')
    $r=New-Object Management.Automation.ErrorRecord($e,'OfflineError',[Management.Automation.ErrorCategory]::InvalidOperation,$null)
    $r.ErrorDetails=New-Object Management.Automation.ErrorDetails(('{"label":"'+$Label+'","message":"mock response"}'))
    throw $r
}
function ApplySwap($q) {
    $src=Asset $script:Data $q.venue $q.from_coin; $dst=Asset $script:Data 'CROSSEX' 'USDT'
    $sold=D $q.from_amount; $bought=D $q.to_amount
    if ($script:Scenario -eq 'no-settlement') { return }
    if ($script:Scenario -eq 'partial') { $sold/=2; $bought/=2 }
    if ($script:Scenario -eq 'available-only') { $src.available_balance='0'; $dst.available_balance=DS $bought; return }
    if ($script:Scenario -ne 'only-credit') { $src.balance=DS ((D $src.balance)-$sold); $src.available_balance=$src.balance }
    if ($script:Scenario -ne 'only-debit') { $dst.balance=DS ((D $dst.balance)+$bought); $dst.available_balance=$dst.balance }
}
function Invoke-RestMethod {
    [CmdletBinding()]
    param($Method,$Uri,$Headers,$Body,$ContentType,[int]$TimeoutSec,[int]$MaximumRedirection,[int]$MaximumRetryCount,[int]$OperationTimeoutSeconds)
    Assert ($Uri -like 'https://api.gateio.ws/api/v4/crossex/*') 'Unexpected mock destination'
    Equal $MaximumRedirection 0; Equal $TimeoutSec 20; Equal $MaximumRetryCount 0
    $Path=([uri]$Uri).AbsolutePath.Substring('/api/v4'.Length)
    $script:LastRequest=[pscustomobject]@{Method=$Method;Path=$Path;Uri=$Uri;Headers=$Headers;Body=$Body;ContentType=$ContentType}
    $null=$script:Calls.Add($script:LastRequest)
    if ($Path -ne '/crossex/transfers/coin') { Equal $Headers.KEY 'OFFLINE-TEST-KEY'; Assert ($Headers.SIGN -match '^[0-9a-f]{128}$') 'Invalid signature shape' }
    $b=$null
    if ($Method -eq 'POST') { Assert ($Body -is [byte[]]) 'POST body must use signed UTF8 bytes'; $b=[Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json }
    switch ($Path) {
        '/crossex/accounts' {
            if ($script:Scenario -eq 'account-http-error') { ApiError 'FORBIDDEN' }
            if ($script:Scenario -eq 'settlement-read-error' -and (CountCalls 'POST' '/crossex/convert/orders') -gt 0) { throw 'Mock read timeout after accepted swap' }
            return CloneMock $script:Data
        }
        '/crossex/open_orders' {
            if ($script:Scenario -eq 'null-list') { return $null }
            if ($script:Scenario -eq 'object-list') { return [pscustomobject]@{} }
            return ,$script:Orders
        }
        '/crossex/positions' { return ,$script:Futures }
        '/crossex/margin_positions' { return ,$script:Margins }
        '/crossex/transfers/coin' { return ,@((CloneMock $script:Rule)) }
        '/crossex/convert/quote' {
            $script:Qn++
            if ($script:Scenario -eq 'unsupported') { ApiError 'CONVERT_TRADE_QUOTE_FROM_COIN_INVALID_ERROR' }
            if ($script:Scenario -eq 'quota-error') { ApiError 'TOO_MANY_REQUESTS' }
            if ($script:Scenario -eq 'quote-auth-error') { ApiError 'INVALID_KEY' }
            Assert ($b.from_amount -is [string]) 'Quote amount must be a JSON string'
            Equal $b.to_coin 'USDT'
            $rate=[decimal]0.9982
            if ($script:Scenario -eq 'preview-loss') { $rate=[decimal]0.98 }
            if ($script:Scenario -eq 'fresh-loss' -and $script:ApprovedSwap) { $rate=[decimal]0.97 }
            if ($script:Scenario -eq 'fresh-better' -and $script:ApprovedSwap) { $rate=[decimal]1.0001 }
            $q=[pscustomobject]@{quote_id=('q'+$script:Qn);valid_ms='5000';from_coin=$b.from_coin;to_coin='USDT';from_amount=$b.from_amount;to_amount=(DS (RoundDown ((D $b.from_amount)*$rate) 8));venue=$b.exchange_type}
            if ($script:Scenario -eq 'wrong-from') { $q.from_coin='BTC' }
            if ($script:Scenario -eq 'wrong-to') { $q.to_coin='BTC' }
            if ($script:Scenario -eq 'wrong-amount') { $q.from_amount='24' }
            if ($script:Scenario -eq 'zero-result') { $q.to_amount='0' }
            if ($script:Scenario -eq 'missing-quote-id') { $q.PSObject.Properties.Remove('quote_id') }
            if ($script:Scenario -eq 'invalid-ttl') { $q.valid_ms='garbage' }
            if ($script:Scenario -eq 'expired') { $q.valid_ms='1' }
            $script:Quotes['q'+$script:Qn]=CloneMock $q
            return $q
        }
        '/crossex/convert/orders' {
            Equal $b.PSObject.Properties.Name.Count 1
            Assert ($script:ApprovedSwap) 'Swap without approval'
            Equal $b.quote_id ('q'+$script:Qn)
            if ($script:Scenario -eq 'swap-timeout-before') { throw 'Mock POST timeout' }
            ApplySwap $script:Quotes[$b.quote_id]
            if ($script:Scenario -eq 'swap-timeout-after') { throw 'Mock POST timeout after server commit' }
            if ($script:Scenario -eq 'missing-order-id') { return [pscustomobject]@{text='9'} }
            return [pscustomobject]@{order_id='2210751276142080';text='2210751276142080'}
        }
        '/crossex/transfers' {
            if ($Method -eq 'POST') {
                Assert ($script:ApprovedTransfer) 'Transfer without approval'
                Equal $b.from 'CROSSEX'; Equal $b.to 'SPOT'; Equal $b.coin 'USDT'
                Assert ($b.amount -is [string]) 'Transfer amount must be a JSON string'
                if ($script:Scenario -eq 'transfer-timeout') { throw 'Mock transfer POST timeout' }
                $script:LastTransfer=$b
                if ($script:Scenario -eq 'missing-tx-id') { return [pscustomobject]@{text='9'} }
                if ($script:Scenario -ne 'transfer-fail') { $dst=Asset $script:Data 'CROSSEX' 'USDT'; $dst.balance=DS ((D $dst.balance)-(D $b.amount)); $dst.available_balance=$dst.balance }
                return [pscustomobject]@{tx_id='38239548890874368';text='38239548890874368'}
            }
            $script:HistoryCount++
            if ($script:Scenario -eq 'empty-history') { return ,@() }
            $amount=if($script:LastTransfer){$script:LastTransfer.amount}else{'12.21616386'}
            $r=[pscustomobject]@{id='38239548890874368';coin='USDT';from_account_type='CROSSEX';to_account_type='SPOT';amount=$amount;status='SUCCESS';actual_receive=(DS ((D $amount)-(D $script:Rule.est_fee)));fail_reason='mock failure'}
            if ($script:Scenario -eq 'pending' -or ($script:Scenario -eq 'pending-then-success' -and $script:HistoryCount -lt 3)) { $r.status='PENDING'; $r.actual_receive=$null }
            if ($script:Scenario -eq 'transfer-fail') { $r.status='FAIL'; $r.actual_receive=$null }
            if ($script:Scenario -eq 'history-wrong-id') { $r.id='999' }
            if ($script:Scenario -eq 'history-wrong-direction') { $r.from_account_type='SPOT' }
            if ($script:Scenario -eq 'history-wrong-amount') { $r.amount='1' }
            if ($script:Scenario -eq 'history-wrong-coin') { $r.coin='USDC' }
            if ($script:Scenario -eq 'history-unknown-status') { $r.status='UNKNOWN' }
            if ($script:Scenario -eq 'history-no-received') { $r.PSObject.Properties.Remove('actual_receive') }
            if ($script:Scenario -eq 'history-zero-received') { $r.actual_receive='0' }
            if ($script:Scenario -eq 'history-huge-received') { $r.actual_receive='999' }
            return ,@($r)
        }
    }
    throw "Unexpected mock path: $Path"
}
$script:Passed=0; $script:Failed=0
function Test([string]$Name,[scriptblock]$Body) {
    Reset
    try { & $Body; $script:Passed++; [Console]::WriteLine("PASS: $Name") }
    catch { $script:Failed++; [Console]::WriteLine("FAIL: $Name -- $($_.Exception.Message) at $($_.ScriptStackTrace)") }
}
[Console]::WriteLine("ENGINE: $($PSVersionTable.PSVersion) $($PSVersionTable.PSEdition); all Gate traffic mocked")
Test 'Decimal dust preserved' { Equal (DS (D '0.00000000000000000194')) '0.00000000000000000194' }
Test 'Decimal trailing digits preserved' { Equal (DS (D '12.21616386000000000194')) '12.21616386000000000194' }
Test 'Decimal exponential input' { Equal (D '1.94e-18') (D '0.00000000000000000194') }
Test 'Decimal null fails closed' { Throws { D $null } }
Test 'Decimal blank fails closed' { Throws { D '' } }
Test 'Decimal garbage fails closed' { Throws { D 'no' } }
Test 'Decimal boolean rejected' { Throws { D $true } }
Test 'Decimal underflow rejected' { Throws { D '1e-29' } }
Test 'Decimal overflow rejected' { Throws { D '79228162514264337593543950336' } }
Test 'Decimal silent rounding rejected' { Throws { D '1.00000000000000000000000000001' } }
Test 'Decimal MaxValue exact' { Equal (D '79228162514264337593543950335') ([decimal]::MaxValue) }
Test 'Decimal locale independent' { $old=[Threading.Thread]::CurrentThread.CurrentCulture;try{[Threading.Thread]::CurrentThread.CurrentCulture='uk-UA'; Equal (DS (D '12.34')) '12.34'}finally{[Threading.Thread]::CurrentThread.CurrentCulture=$old} }
Test 'Round precision zero' { Equal (RoundDown (D '12.99') 0) ([decimal]12) }
Test 'Round precision eight' { Equal (RoundDown (D '12.21616386000000000194') 8) (D '12.21616386') }
Test 'Round huge amount no overflow' { Equal (RoundDown ([decimal]::MaxValue) 28) ([decimal]::MaxValue) }
Test 'Round negative rejected' { Throws { RoundDown -1 8 } }
Test 'Round invalid precision rejected' { Throws { RoundDown 1 29 } }
Test 'Round never upward: 300 cases' { for($i=1;$i -le 300;$i++){ $v=[decimal]$i/37; $p=$i%12; $r=RoundDown $v $p; Assert ($r -le $v) } }
Test 'Missing required field rejected' { Throws { N ([pscustomobject]@{}) 'balance' } }
Test 'Fractional precision rejected' { Throws { IntegerField ([pscustomobject]@{p='8.5'}) 'p' 0 28 } }
Test 'Empty list preserved' { $x=List '/crossex/open_orders'; Assert ($x -is [array]); Equal $x.Count 0 }
Test 'Null list rejected' { $script:Scenario='null-list'; Throws { SafeAccount 'offline-user' }; NoWrites }
Test 'Object instead of array rejected' { $script:Scenario='object-list'; Throws { SafeAccount 'offline-user' }; NoWrites }
Test 'Missing assets rejected' { $script:Data.PSObject.Properties.Remove('assets'); Throws { Account } }
Test 'Duplicate assets rejected' { $script:Data.assets+=CloneMock $script:Data.assets[0]; Throws { Account } }
Test 'Missing margin blocks cleaner' { $script:Data.PSObject.Properties.Remove('initial_margin'); Throws { RunCleaner }; NoWrites }
Test 'Nonzero liability blocks cleaner' { $script:Data.assets[0].liability='1'; Throws { RunCleaner }; NoWrites }
Test 'Nonzero upnl blocks cleaner' { $script:Data.assets[0].upnl='-1'; Throws { RunCleaner }; NoWrites }
Test 'Negative balance blocks cleaner' { $script:Data.assets[0].balance='-1'; Throws { RunCleaner }; NoWrites }
Test 'Isolated mode blocks full cleaner' { $script:Data.account_mode='ISOLATED_EXCHANGE'; Throws { RunCleaner }; NoWrites }
Test 'Zero futures row is not an active position' { $script:Futures=@([pscustomobject]@{position_qty='0';initial_margin='0';maintenance_margin='0';upnl='0'}); $null=SafeAccount 'offline-user' }
Test 'Unknown position shape fails closed' { $script:Futures=@([pscustomobject]@{}); Throws { SafeAccount 'offline-user' } }
Test 'SHA512 empty known vector' { Equal (Sha512 '') 'cf83e1357eefb8bdf1542850d66d8007d620e4050b5715dc83f4a921d36ce9ce47d0d13c5d85f2b0ff8318d2877eec2f63b931bd47417a81a538327af927da3e' }
Test 'UTC timestamp correct' { Assert ([Math]::Abs((& $script:RealUtc)-[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) -lt 2) }
Test 'GET signed bytes match independent Python vector' { $null=Account; Equal $script:LastRequest.Headers.SIGN '37147eeb663b72af7aa99b9b2c9225897aebb971371c4b73b8db147801f0f4be4d44aa9a4408d6fed3507cf89a114ff85751c42a983520559ea8b72abd12ce2c' }
Test 'POST signed bytes match independent Python vector' { $null=Quote 'HYPERLIQUID' 'USDC' (D '12.23696671'); Equal $script:LastRequest.Headers.SIGN '82adc513d7b92c6166f9bd12ae7528132fd64fd711ca9416d4192fff35833e0af95bfce2352961a11fa46b148176624fa27cd8a023ea66c94e024a85e2204edd' }
Test 'GET query signing matches independent Python vector' { $null=List '/crossex/transfers' 'order_id=38239548890874368&limit=10'; Equal $script:LastRequest.Headers.SIGN '0bc5a2c8b9d92a97869e230753cafd8fa34448bd21a845c9dc87187457931763851ce77b8c676ea522aa3d38079b50315c989d018211dd1d0129992c361b1aa5' }
Test 'Withdrawal endpoint is inaccessible' { Throws { Gate 'POST' '/withdrawals' }; Equal $script:Calls.Count 0 }
Test 'Unsigned private endpoint blocked' { Throws { Gate 'GET' '/crossex/accounts' '' $null $false }; Equal $script:Calls.Count 0 }
Test 'Error redaction' { Equal (Redact 'OFFLINE-TEST-KEY / OFFLINE-TEST-SECRET') '[REDACTED] / [REDACTED]' }
Test 'Read-only makes exactly one GET' { RunCleaner $true; Equal $script:Calls.Count 1; NoWrites }
Test 'Zero account performs no mutations' { $script:Data.assets=@(); RunCleaner; NoWrites }
Test 'Dust below minimum is not transferred' { OnlyUsdt '0.00000000000000000194'; RunCleaner; NoWrites }
Test 'USDT-only transfer rounds down once' { OnlyUsdt; RunCleaner; Equal (CountCalls 'POST' '/crossex/transfers') 1; Equal (CountCalls 'POST' '/crossex/convert/orders') 0; Equal $script:LastTransfer.amount '12.21616386'; Equal $script:PendingOperation $null }
Test 'End to end USDC swap then transfer once' { RunCleaner; Equal (CountCalls 'POST' '/crossex/convert/quote') 2; Equal (CountCalls 'POST' '/crossex/convert/orders') 1; Equal (CountCalls 'POST' '/crossex/transfers') 1; Equal $script:PendingOperation $null }
Test 'End to end several venues' { $script:Data.assets+=(MakeAsset 'GATE' 'BTC' '0.0002'); RunCleaner; Equal (CountCalls 'POST' '/crossex/convert/orders') 2; Equal (CountCalls 'POST' '/crossex/transfers') 1 }
Test 'Cancel quote preview' { $script:Answers.Clear();$script:Answers.Enqueue('');RunCleaner; Equal (CountCalls 'POST' '/crossex/convert/quote') 0;NoWrites }
Test 'Cancel swap' { $script:Answers.Clear();$script:Answers.Enqueue('YES');$script:Answers.Enqueue('');RunCleaner;NoWrites }
Test 'Cancel transfer' { OnlyUsdt;$script:Answers.Clear();$script:Answers.Enqueue('');RunCleaner;NoWrites }
Test 'Case-sensitive YES' { $script:Answers.Clear();$script:Answers.Enqueue('yes'); Equal (Yes 'confirm') $false }
Test 'Unsupported coin is skipped' { $script:Scenario='unsupported';RunCleaner;NoWrites }
Test 'Quota stops rather than loops' { $script:Scenario='quota-error';Throws {RunCleaner};Equal (CountCalls 'POST' '/crossex/convert/quote') 1;NoWrites }
Test 'Authentication error is not called unsupported coin' { $script:Scenario='quote-auth-error';Throws {RunCleaner};NoWrites }
foreach ($Case in @('wrong-from','wrong-to','wrong-amount','zero-result','missing-quote-id','invalid-ttl','expired','source-increase','source-decrease','new-order','new-future')) {
    Test "Pre-swap safety: $Case" { $script:Scenario=$Case;Throws {RunCleaner};NoWrites }
}
foreach ($Case in @('preview-loss','fresh-loss')) { Test "Quote guard: $Case" { $script:Scenario=$Case;RunCleaner;NoWrites } }
Test 'Better fresh quote accepted' { $script:Scenario='fresh-better';RunCleaner;Equal (CountCalls 'POST' '/crossex/convert/orders') 1 }
foreach ($Case in @('swap-timeout-before','swap-timeout-after','missing-order-id','partial','available-only','only-credit','only-debit','no-settlement','settlement-read-error')) {
    Test "Ambiguous swap blocks further money movement: $Case" { $script:Scenario=$Case;Throws {RunCleaner};Equal (CountCalls 'POST' '/crossex/convert/orders') 1;Equal (CountCalls 'POST' '/crossex/transfers') 0;Assert (-not [string]::IsNullOrEmpty($script:PendingOperation)) }
}
foreach ($Case in @('fee-change','precision-change','minimum-change','transfer-balance-change','new-margin')) {
    Test "Recheck after transfer approval: $Case" { OnlyUsdt;$script:Scenario=$Case;Throws {RunCleaner};NoWrites }
}
Test 'Missing transfer precision rejected' { OnlyUsdt;$script:Rule.PSObject.Properties.Remove('precision');Throws {RunCleaner};NoWrites }
Test 'Missing transfer fee rejected' { OnlyUsdt;$script:Rule.PSObject.Properties.Remove('est_fee');Throws {RunCleaner};NoWrites }
Test 'Disabled transfer blocked' { OnlyUsdt;$script:Rule.is_disabled=1;Throws {RunCleaner};NoWrites }
Test 'Amount does not cover fee' { OnlyUsdt '1';$script:Rule.est_fee=2;RunCleaner;NoWrites }
Test 'Fee is not subtracted twice' { OnlyUsdt '12';$script:Rule.est_fee=1;RunCleaner;Equal $script:LastTransfer.amount '12';Assert (($script:Output -join ' ') -like '*actual_receive=11*') }
Test 'Per-run candidate limit enforced' { $script:MaxCandidates=1;$script:Data.assets+=(MakeAsset 'GATE' 'BTC' '0.01');Throws {RunCleaner};Equal (CountCalls 'POST' '/crossex/convert/quote') 0 }
Test 'Per-run quote budget enforced' { $script:QuoteRequests=80;Throws {Quote 'GATE' 'BTC' (D '0.01')};Equal $script:Calls.Count 0 }
foreach ($Case in @('pending','empty-history','history-wrong-id','history-wrong-direction','history-wrong-amount','history-wrong-coin','history-unknown-status','history-no-received','history-zero-received','history-huge-received','transfer-timeout','missing-tx-id')) {
    Test "Transfer uncertainty never retried: $Case" { OnlyUsdt;$script:Scenario=$Case;Throws {RunCleaner};Equal (CountCalls 'POST' '/crossex/transfers') 1;Assert (-not [string]::IsNullOrEmpty($script:PendingOperation));Assert (($script:Output -join ' ') -notlike '*Transfer FAIL*') }
}
Test 'Terminal transfer FAIL distinguished from PENDING' { OnlyUsdt;$script:Scenario='transfer-fail';Throws {RunCleaner} '*Transfer FAIL*';Equal (CountCalls 'POST' '/crossex/transfers') 1;Equal $script:PendingOperation $null }
Test 'Pending then success confirmed' { OnlyUsdt;$script:Scenario='pending-then-success';RunCleaner;Equal (CountCalls 'POST' '/crossex/transfers') 1;Equal $script:HistoryCount 3 }
Test 'Balances-only original entrypoint and key cleanup' {
    $old=[Net.ServicePointManager]::SecurityProtocol
    & ([scriptblock]::Create($Source)) -BalancesOnly
    Equal $script:Calls.Count 1
    NoWrites
    Equal $script:ApiKey $null
    Equal $script:ApiSecret $null
    Equal ([Net.ServicePointManager]::SecurityProtocol) $old
}
Test 'Full original entrypoint including mutex and transfer' {
    OnlyUsdt
    & ([scriptblock]::Create($Source))
    Equal (CountCalls 'POST' '/crossex/transfers') 1
    Equal $script:ApiKey $null
    Equal $script:ApiSecret $null
}
Test 'Original entrypoint rejects unsafe percent before API call' {
    Throws { & ([scriptblock]::Create($Source)) -MaxQuoteWorseningPercent 100 } '*Percentage limits*'
    Equal $script:Calls.Count 0
}
[Console]::WriteLine("RESULT: $script:Passed passed; $script:Failed failed. Gate HTTP requests: 0 (all simulated).")
if ($script:Failed -gt 0) { throw "$script:Failed offline tests failed" }
