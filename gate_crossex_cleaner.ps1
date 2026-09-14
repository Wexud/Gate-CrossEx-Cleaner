#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$BalancesOnly,
    [decimal]$MaxQuoteWorseningPercent = 1.0,
    [decimal]$StablecoinMaxLossPercent = 1.0,
    [ValidateRange(1,40)][int]$MaxCandidates = 40
)

# Gate CrossEx Cleaner
# Version: 1.0.5
# Windows PowerShell 5.1 / PowerShell 7. No blockchain withdrawals.
$ErrorActionPreference = 'Stop'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$ApiHost = 'https://api.gateio.ws'
$Prefix = '/api/v4'
$SupportedVenues = @('BINANCE','OKX','GATE','BYBIT','KRAKEN','HYPERLIQUID')
$script:QuoteRequests = 0
$script:PendingOperation = $null
$script:ApiKey = $null
$script:ApiSecret = $null

function Field($Object, [string]$Name) {
    if ($null -eq $Object) { throw "Missing object for field '$Name'." }
    if ($Object -is [Collections.IDictionary]) {
        if (-not $Object.Contains($Name)) { throw "Missing field '$Name'." }
        return ,$Object[$Name]
    }
    $Property = $Object.PSObject.Properties[$Name]
    if ($null -eq $Property) { throw "Missing field '$Name'." }
    return ,$Property.Value
}
function TextField($Object, [string]$Name) {
    $Value = Field $Object $Name
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "Invalid text field '$Name'."
    }
    return $Value
}
function CanonicalNumber($Value) {
    if ($null -eq $Value -or $Value -is [bool]) { throw 'Missing or invalid number.' }
    $Text = [Convert]::ToString($Value, $Inv).Trim()
    if ($Value -is [double] -or $Value -is [single]) { $Text = $Value.ToString('R', $Inv) }
    $Match = [regex]::Match($Text, '^([+-]?)([0-9]+)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?$')
    if (-not $Match.Success -or $Text.Length -gt 160) { throw 'Invalid decimal number.' }
    $Exponent = 0
    if ($Match.Groups[4].Success) { $Exponent = [int]$Match.Groups[4].Value }
    if ($Exponent -lt -100 -or $Exponent -gt 100) { throw 'Decimal exponent out of range.' }
    $Digits = $Match.Groups[2].Value + $Match.Groups[3].Value
    $Point = $Match.Groups[2].Length + $Exponent
    if ($Point -le 0) { $Whole = '0'; $Fraction = ('0' * (-$Point)) + $Digits }
    elseif ($Point -ge $Digits.Length) { $Whole = $Digits + ('0' * ($Point - $Digits.Length)); $Fraction = '' }
    else { $Whole = $Digits.Substring(0,$Point); $Fraction = $Digits.Substring($Point) }
    $Whole = $Whole.TrimStart('0'); if ($Whole.Length -eq 0) { $Whole = '0' }
    $Fraction = $Fraction.TrimEnd('0')
    $Result = $Whole; if ($Fraction.Length) { $Result += '.' + $Fraction }
    if ($Result -ne '0' -and $Match.Groups[1].Value -eq '-') { $Result = '-' + $Result }
    return $Result
}
function DS([decimal]$Value) { return $Value.ToString('0.############################', $Inv) }
function D($Value, [string]$Name = 'value') {
    try {
        $Canonical = CanonicalNumber $Value
        $Number = [decimal]::Parse($Canonical, [Globalization.NumberStyles]::AllowLeadingSign -bor [Globalization.NumberStyles]::AllowDecimalPoint, $Inv)
        if ((DS $Number) -cne $Canonical) { throw 'Would round the original value.' }
        return $Number
    } catch { throw "Invalid or unrepresentable decimal field '${Name}'. No zero was substituted." }
}
function N($Object, [string]$Name) { return D (Field $Object $Name) $Name }
function IntegerField($Object, [string]$Name, [int]$Minimum, [int]$Maximum) {
    $Value = N $Object $Name
    if ($Value -lt $Minimum -or $Value -gt $Maximum -or [decimal]::Truncate($Value) -ne $Value) {
        throw "Invalid integer field '$Name'."
    }
    return [int]$Value
}
function Pct([decimal]$Value) { return $Value.ToString('0.0000', $Inv) + '%' }
function UnixTime { return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function Sha512([string]$Text) {
    $Hash = [Security.Cryptography.SHA512]::Create()
    try { return ([BitConverter]::ToString($Hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant() }
    finally { $Hash.Dispose() }
}
function Hmac512([string]$Key, [string]$Text) {
    $Hash = New-Object Security.Cryptography.HMACSHA512
    try {
        $Hash.Key = [Text.Encoding]::UTF8.GetBytes($Key)
        return ([BitConverter]::ToString($Hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)))).Replace('-','').ToLowerInvariant()
    } finally { $Hash.Dispose() }
}
function Redact([string]$Text) {
    foreach ($Secret in @($script:ApiKey,$script:ApiSecret)) {
        if (-not [string]::IsNullOrEmpty($Secret)) { $Text = $Text.Replace($Secret,'[REDACTED]') }
    }
    $Text = $Text -replace '[\x00-\x08\x0b-\x1f\x7f]', ''
    if ($Text.Length -gt 2000) { $Text = $Text.Substring(0,2000) }
    return $Text
}
function HttpFailure($ErrorRecord, [string]$Method, [string]$Path) {
    $Body = ''; $Label = ''
    if ($ErrorRecord.ErrorDetails) { $Body = [string]$ErrorRecord.ErrorDetails.Message }
    if ([string]::IsNullOrWhiteSpace($Body)) {
        try {
            $Response = $ErrorRecord.Exception.Response
            if ($Response -is [Net.HttpWebResponse]) {
                $Reader = New-Object IO.StreamReader($Response.GetResponseStream())
                try { $Body = $Reader.ReadToEnd() } finally { $Reader.Dispose() }
            } elseif ($null -ne $Response.Content) {
                $Body = $Response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            }
        } catch { $Body = '' }
    }
    try { $Parsed = $Body | ConvertFrom-Json -ErrorAction Stop; $Label = [string]$Parsed.label } catch {}
    $Message = Redact ("Gate API $Method $Path failed: " + $ErrorRecord.Exception.Message + ' | ' + $Body)
    $Failure = New-Object System.InvalidOperationException($Message)
    $Failure.Data['GateLabel'] = $Label
    return $Failure
}
function Gate([string]$Method, [string]$Path, [string]$Query = '', $Body = $null, [bool]$Signed = $true) {
    $AllowedGet = @('/crossex/accounts','/crossex/open_orders','/crossex/positions','/crossex/margin_positions','/crossex/transfers/coin','/crossex/transfers')
    $AllowedPost = @('/crossex/convert/quote','/crossex/convert/orders','/crossex/transfers')
    if (($Method -ceq 'GET' -and $AllowedGet -notcontains $Path) -or
        ($Method -ceq 'POST' -and $AllowedPost -notcontains $Path) -or
        @('GET','POST') -cnotcontains $Method) { throw 'Unexpected API operation.' }
    if (-not $Signed -and $Path -ne '/crossex/transfers/coin') { throw 'Unsigned private request blocked.' }
    $BodyText = ''; if ($null -ne $Body) { $BodyText = $Body | ConvertTo-Json -Compress -Depth 10 }
    $Uri = "$ApiHost$Prefix$Path"; if ($Query) { $Uri += '?' + $Query }
    $Headers = @{ Accept = 'application/json' }
    if ($Signed) {
        $Timestamp = (UnixTime).ToString($Inv)
        $SignText = $Method + "`n" + $Prefix + $Path + "`n" + $Query + "`n" + (Sha512 $BodyText) + "`n" + $Timestamp
        $Headers.KEY = $script:ApiKey; $Headers.Timestamp = $Timestamp
        $Headers.SIGN = Hmac512 $script:ApiSecret $SignText
    }
    $Params = @{ Method=$Method; Uri=$Uri; Headers=$Headers; TimeoutSec=20; MaximumRedirection=0; ErrorAction='Stop'; Verbose=$false; Debug=$false }
    # 7.4+ separates connection and stream-read timeouts; 5.1 has TimeoutSec only.
    $Parameters = (Get-Command Invoke-RestMethod).Parameters
    if ($Parameters.ContainsKey('OperationTimeoutSeconds')) { $Params.OperationTimeoutSeconds = 20 }
    if ($Parameters.ContainsKey('MaximumRetryCount')) { $Params.MaximumRetryCount = 0 }
    if ($null -ne $Body) { $Params.Body = [Text.Encoding]::UTF8.GetBytes($BodyText); $Params.ContentType = 'application/json; charset=utf-8' }
    try {
        $Result = Invoke-RestMethod @Params
        # Preserve [] as an array, instead of confusing it with a missing response.
        return ,$Result
    } catch { throw (HttpFailure $_ $Method $Path) }
}
function ArrayResponse($Value, [string]$Name) {
    if ($null -eq $Value -or $Value -isnot [array]) { throw "Expected an array from $Name; safety check failed." }
    foreach ($Item in $Value) { if ($null -eq $Item -or $Item -is [array]) { throw "Invalid row in $Name." } }
    return ,$Value
}
function List([string]$Path, [string]$Query = '', [bool]$Signed = $true) {
    return ,(ArrayResponse (Gate 'GET' $Path $Query $null $Signed) $Path)
}
function Account {
    $AccountData = Gate 'GET' '/crossex/accounts'
    $null = TextField $AccountData 'user_id'
    $null = TextField $AccountData 'account_mode'
    $Assets = ArrayResponse (Field $AccountData 'assets') 'accounts.assets'
    $Seen = @{}
    foreach ($Item in $Assets) {
        $Venue = TextField $Item 'exchange_type'; $Coin = TextField $Item 'coin'
        $Key = $Venue + '/' + $Coin
        if ($Seen.ContainsKey($Key)) { throw "Duplicate asset $Key." }; $Seen[$Key] = $true
        $null = N $Item 'balance'; $null = N $Item 'available_balance'
    }
    return $AccountData
}
function Asset($AccountData, [string]$Venue, [string]$Coin) {
    foreach ($Item in $AccountData.assets) {
        if ($Item.exchange_type -eq $Venue -and $Item.coin -eq $Coin) { return $Item }
    }
    return $null
}
function AmountOf($AccountData, [string]$Venue, [string]$Coin, [string]$FieldName) {
    $Item = Asset $AccountData $Venue $Coin
    if ($null -eq $Item) { return [decimal]0 }
    return N $Item $FieldName
}
function UsdtAvailable($AccountData) { return AmountOf $AccountData 'CROSSEX' 'USDT' 'available_balance' }
function ShowBalances($AccountData) {
    Write-Host ''; Write-Host 'Current non-zero CrossEx balances:' -ForegroundColor Cyan
    foreach ($Item in $AccountData.assets) {
        $Debt = N $Item 'liability'
        if ((N $Item 'balance') -ne 0 -or (N $Item 'available_balance') -ne 0 -or $Debt -ne 0) {
            Write-Host ('{0,-13} {1,-10} balance={2}  available={3}  liability={4}' -f $Item.exchange_type,$Item.coin,$Item.balance,$Item.available_balance,$Item.liability)
        }
    }
}
function RiskReasons($AccountData) {
    $Reasons = @()
    foreach ($Name in @('initial_margin','maintenance_margin')) {
        if ((N $AccountData $Name) -ne 0) { $Reasons += $Name }
    }
    foreach ($Item in $AccountData.assets) {
        foreach ($Name in @('liability','upnl','futures_initial_margin','futures_maintenance_margin','borrowing_initial_margin','borrowing_maintenance_margin')) {
            if ((N $Item $Name) -ne 0) { $Reasons += "$($Item.exchange_type) $($Item.coin) $Name" }
        }
        if ((N $Item 'balance') -lt 0 -or (N $Item 'available_balance') -lt 0) { $Reasons += 'Negative asset balance' }
    }
    return $Reasons
}
function SafeAccount([string]$ExpectedUser) {
    $Orders = List '/crossex/open_orders'
    if ($Orders.Count -gt 0) { throw 'Active open orders detected. No further operation.' }
    $Futures = List '/crossex/positions'
    foreach ($Position in $Futures) {
        foreach ($Name in @('position_qty','initial_margin','maintenance_margin','upnl')) {
            if ((N $Position $Name) -ne 0) { throw 'Active futures position detected.' }
        }
    }
    $Margins = List '/crossex/margin_positions'
    foreach ($Position in $Margins) {
        foreach ($Name in @('asset_qty','liability','interest','initial_margin','maintenance_margin','upnl')) {
            if ((N $Position $Name) -ne 0) { throw 'Active margin position or debt detected.' }
        }
    }
    $AccountData = Account
    if ($AccountData.user_id -cne $ExpectedUser) { throw 'Account identity changed.' }
    if ($AccountData.account_mode -cne 'CROSS_EXCHANGE') { throw 'Full cleaner requires CROSS_EXCHANGE mode.' }
    $Risks = @(RiskReasons $AccountData)
    if ($Risks.Count) { throw ('Active exposure: ' + ($Risks -join ', ')) }
    return $AccountData
}
function Candidates($AccountData) {
    foreach ($Item in $AccountData.assets) {
        $Venue = $Item.exchange_type.ToUpperInvariant(); $Coin = $Item.coin.ToUpperInvariant()
        if ((N $Item 'available_balance') -le 0) { continue }
        if ($Venue -eq 'CROSSEX' -and $Coin -eq 'USDT') { continue }
        if ($Coin -eq 'USDT' -or $SupportedVenues -notcontains $Venue) {
            Write-Host "SKIP $Venue $Coin: no automatic route to CROSSEX USDT." -ForegroundColor Yellow
            continue
        }
        $Item
    }
}
function Quote([string]$Venue, [string]$Coin, [decimal]$Amount) {
    if ($Amount -le 0) { throw 'Non-positive quote amount.' }
    if ($script:QuoteRequests -ge (2 * $MaxCandidates)) { throw 'Per-run quote budget exhausted.' }
    $script:QuoteRequests++
    $Clock = [Diagnostics.Stopwatch]::StartNew()
    $Result = Gate 'POST' '/crossex/convert/quote' '' ([ordered]@{exchange_type=$Venue;from_coin=$Coin;to_coin='USDT';from_amount=(DS $Amount)})
    $null = TextField $Result 'quote_id'
    if ((TextField $Result 'from_coin') -cne $Coin -or (TextField $Result 'to_coin') -cne 'USDT') { throw 'Quote currency mismatch.' }
    if ((N $Result 'from_amount') -ne $Amount -or (N $Result 'to_amount') -le 0) { throw 'Quote amount mismatch or non-positive result.' }
    $Ttl = IntegerField $Result 'valid_ms' 1 60000
    $Result | Add-Member -NotePropertyName '_Clock' -NotePropertyValue $Clock -Force
    $Result | Add-Member -NotePropertyName '_Ttl' -NotePropertyValue $Ttl -Force
    return $Result
}
function SkippableQuote($ErrorRecord) {
    $Label = [string]$ErrorRecord.Exception.Data['GateLabel']
    return $Label -match '^CONVERT_TRADE_QUOTE_(EXCHANGE_INVALID|FROM_COIN_INVALID|TO_COIN_INVALID|FROM_AMOUNT_INVALID|FROM_AMOUNT_LIMIT|FROM_AMOUNT_MAX|EXCHANGE_REJECT)_ERROR$'
}
function Rate($QuoteData) { return (N $QuoteData 'to_amount') / (N $QuoteData 'from_amount') }
function Worse([decimal]$PreviewRate, [decimal]$FreshRate) {
    if ($PreviewRate -le 0 -or $FreshRate -le 0) { throw 'Invalid effective quote rate.' }
    if ($FreshRate -ge $PreviewRate) { return [decimal]0 }
    return (($PreviewRate - $FreshRate) / $PreviewRate) * 100
}
function StableLoss([decimal]$EffectiveRate) {
    if ($EffectiveRate -le 0) { throw 'Invalid stablecoin rate.' }
    if ($EffectiveRate -ge 1) { return [decimal]0 }
    return (1 - $EffectiveRate) * 100
}
function QuoteAllowed($QuoteData, [string]$Coin, [decimal]$PreviewRate = 0) {
    $CurrentRate = Rate $QuoteData
    if ($CurrentRate -le 0) { throw 'Unrepresentable effective rate.' }
    if ($PreviewRate -gt 0 -and (Worse $PreviewRate $CurrentRate) -gt $MaxQuoteWorseningPercent) { return $false }
    if (@('USDC','USD') -contains $Coin -and (StableLoss $CurrentRate) -gt $StablecoinMaxLossPercent) { return $false }
    return $true
}
function ExecuteQuote($QuoteData) {
    # Budget includes the quote request itself; do not wait for input after quoting.
    if ($QuoteData._Clock.ElapsedMilliseconds + 300 -ge $QuoteData._Ttl) { throw 'Fresh quote expired or too close to expiry; no swap POST sent.' }
    $script:PendingOperation = 'Flash Swap quote_id=' + $QuoteData.quote_id
    return Gate 'POST' '/crossex/convert/orders' '' ([ordered]@{quote_id=[string]$QuoteData.quote_id})
}
function WaitSettlement($Before, [string]$Venue, [string]$Coin, $QuoteData, [int]$Seconds = 30) {
    $SourceBefore = AmountOf $Before $Venue $Coin 'balance'
    $UsdtBefore = AmountOf $Before 'CROSSEX' 'USDT' 'balance'
    $Sold = N $QuoteData 'from_amount'; $Bought = N $QuoteData 'to_amount'
    $Clock = [Diagnostics.Stopwatch]::StartNew()
    while ($Clock.Elapsed.TotalSeconds -lt $Seconds) {
        Start-Sleep -Milliseconds 1000
        $Current = Account
        if ($Current.user_id -cne $Before.user_id -or $Current.account_mode -cne 'CROSS_EXCHANGE') { throw 'Account changed during settlement.' }
        $Debited = $SourceBefore - (AmountOf $Current $Venue $Coin 'balance')
        $Credited = (AmountOf $Current 'CROSSEX' 'USDT' 'balance') - $UsdtBefore
        # Any small movement or reserved available balance is NOT full settlement.
        if ($Debited -eq $Sold -and $Credited -eq $Bought) { return $true }
    }
    return $false
}
function RoundDown([decimal]$Number, [int]$Precision) {
    if ($Number -lt 0 -or $Precision -gt 28 -or $Precision -lt 0) { throw 'Invalid amount or precision.' }
    # String truncation avoids Decimal overflow from amount * 10^precision.
    $Parts = (DS $Number).Split('.')
    if ($Precision -eq 0 -or $Parts.Length -eq 1) { return D $Parts[0] }
    $Fraction = $Parts[1].Substring(0,[Math]::Min($Precision,$Parts[1].Length))
    return D ($Parts[0] + '.' + $Fraction)
}
function TransferRule {
    $Rows = List '/crossex/transfers/coin' 'coin=USDT' $false
    $Matches = @($Rows | Where-Object { $_.coin -ceq 'USDT' })
    if ($Matches.Count -ne 1) { throw 'Expected exactly one USDT transfer rule.' }
    $Rule = $Matches[0]
    $null = IntegerField $Rule 'is_disabled' 0 1
    $null = IntegerField $Rule 'precision' 0 28
    if ((N $Rule 'min_trans_amount') -lt 0 -or (N $Rule 'est_fee') -lt 0) { throw 'Invalid transfer fee/minimum.' }
    return $Rule
}
function TransferPlan($AccountData, $Rule) {
    if ((N $Rule 'is_disabled') -ne 0) { throw 'USDT transfer is disabled by Gate.' }
    $Amount = RoundDown (UsdtAvailable $AccountData) (IntegerField $Rule 'precision' 0 28)
    $Fee = N $Rule 'est_fee'; $Minimum = N $Rule 'min_trans_amount'
    if ($Amount -le 0 -or $Amount -lt $Minimum -or $Amount -le $Fee) { return $null }
    return [pscustomobject]@{Amount=$Amount;Fee=$Fee;Minimum=$Minimum;Precision=[int]$Rule.precision}
}
function Transfer([decimal]$Amount) {
    if ($Amount -le 0) { throw 'Non-positive transfer amount.' }
    $script:PendingOperation = 'CROSSEX -> SPOT transfer amount=' + (DS $Amount)
    return Gate 'POST' '/crossex/transfers' '' ([ordered]@{coin='USDT';amount=(DS $Amount);from='CROSSEX';to='SPOT'})
}
function WaitTransfer([string]$TxId, [decimal]$Amount, [int]$Seconds = 30) {
    $Clock = [Diagnostics.Stopwatch]::StartNew()
    while ($Clock.Elapsed.TotalSeconds -lt $Seconds) {
        $Rows = List '/crossex/transfers' ('order_id=' + [Uri]::EscapeDataString($TxId) + '&limit=10')
        $Matches = @($Rows | Where-Object { $_.id -ceq $TxId })
        if ($Matches.Count -gt 1) { throw 'Duplicate transfer history records.' }
        if ($Matches.Count -eq 1) {
            $Row = $Matches[0]
            if ((TextField $Row 'coin') -cne 'USDT' -or (N $Row 'amount') -ne $Amount -or
                (TextField $Row 'from_account_type') -cne 'CROSSEX' -or (TextField $Row 'to_account_type') -cne 'SPOT') { throw 'Transfer history does not match request.' }
            $Status = TextField $Row 'status'
            if ($Status -ceq 'SUCCESS') {
                $Received = N $Row 'actual_receive'
                if ($Received -le 0 -or $Received -gt $Amount) { throw 'Invalid credited transfer amount.' }
                return $Row
            }
            if ($Status -ceq 'FAIL') { return $Row }
            if ($Status -cne 'PENDING') { throw "Unknown transfer status '$Status'." }
        }
        Start-Sleep -Milliseconds 1000
    }
    return [pscustomobject]@{status='PENDING';id=$TxId}
}
function Yes([string]$Question) { return ((Read-Host $Question).Trim() -ceq 'YES') }
function RunCleaner([bool]$ReadOnly = $false) {
    $Current = Account; ShowBalances $Current
    if ($ReadOnly) { Write-Host 'Balances-only mode: no financial operations were performed.'; return }
    $UserId = TextField $Current 'user_id'
    $Current = SafeAccount $UserId
    Write-Host 'Stop other trading/transfer tools for this account while this cleaner runs.'
    Write-Host "Limits: quote worsening $(Pct $MaxQuoteWorseningPercent); USDC/USD loss $(Pct $StablecoinMaxLossPercent)."
    $Items = @(Candidates $Current)
    if ($Items.Count -gt $MaxCandidates) { throw 'Too many candidates for the per-run quote budget.' }
    $Previews = @()
    if ($Items.Count -gt 0 -and (Yes 'Request preview quotes now? Type YES')) {
        foreach ($Item in $Items) {
            $Venue = $Item.exchange_type.ToUpperInvariant(); $Coin = $Item.coin.ToUpperInvariant()
            $Amount = N $Item 'available_balance'
            try { $QuoteData = Quote $Venue $Coin $Amount }
            catch { if (SkippableQuote $_) { Write-Host (Redact "SKIP $Venue ${Coin}: $($_.Exception.Message)"); continue }; throw }
            if (-not (QuoteAllowed $QuoteData $Coin)) { Write-Host "SKIP $Venue ${Coin}: loss limit."; continue }
            $Previews += [pscustomobject]@{Venue=$Venue;Coin=$Coin;Amount=$Amount;Rate=(Rate $QuoteData)}
            Write-Host "$Venue $Coin $(DS $Amount) -> $($QuoteData.to_amount) USDT"
        }
    }
    if ($Previews.Count -gt 0 -and (Yes 'Execute accepted Flash Swaps? Type YES')) {
        foreach ($Preview in $Previews) {
            Start-Sleep -Milliseconds 1100
            $Current = SafeAccount $UserId
            $Amount = AmountOf $Current $Preview.Venue $Preview.Coin 'available_balance'
            if ($Amount -ne $Preview.Amount) { throw 'Source amount changed since approval. No further swaps.' }
            try { $QuoteData = Quote $Preview.Venue $Preview.Coin $Preview.Amount }
            catch { if (SkippableQuote $_) { Write-Host (Redact "SKIP fresh quote: $($_.Exception.Message)"); continue }; throw }
            if (-not (QuoteAllowed $QuoteData $Preview.Coin $Preview.Rate)) { Write-Host 'SKIP: fresh quote exceeded loss limit.'; continue }
            $Order = ExecuteQuote $QuoteData
            $OrderId = TextField $Order 'order_id'
            $script:PendingOperation = 'Flash Swap order_id=' + $OrderId
            Write-Host "Gate accepted Flash Swap. order_id=$OrderId"
            if (-not (WaitSettlement $Current $Preview.Venue $Preview.Coin $QuoteData)) { throw 'Full quoted balance changes not confirmed. Check Gate before rerun.' }
            $script:PendingOperation = $null
            Write-Host 'Quoted amounts reflected in balances.'
        }
    }
    $Current = SafeAccount $UserId; ShowBalances $Current
    if ((UsdtAvailable $Current) -le 0) { Write-Host 'No CROSSEX USDT available for SPOT transfer.'; return }
    $Rule = TransferRule; $Plan = TransferPlan $Current $Rule
    if ($null -eq $Plan) { Write-Host 'Transfer amount is below minimum or does not cover the estimated fee.'; return }
    Write-Host "CROSSEX USDT -> SPOT: amount=$(DS $Plan.Amount), estimated fee=$(DS $Plan.Fee), estimated receive=$(DS ($Plan.Amount - $Plan.Fee))"
    Write-Host 'This includes USDT already present before this run.'
    if (-not (Yes "Transfer $(DS $Plan.Amount) USDT to SPOT? Type YES")) { Write-Host 'Transfer cancelled.'; return }
    # Human confirmation can take minutes: recheck risk, amount AND rule after it.
    $Current = SafeAccount $UserId; $FreshRule = TransferRule; $FreshPlan = TransferPlan $Current $FreshRule
    if ($null -eq $FreshPlan -or $FreshPlan.Amount -ne $Plan.Amount -or $FreshPlan.Fee -ne $Plan.Fee -or
        $FreshPlan.Minimum -ne $Plan.Minimum -or $FreshPlan.Precision -ne $Plan.Precision) { throw 'Transfer balance or rule changed after approval. No transfer sent.' }
    $Reply = Transfer $Plan.Amount
    $TxId = TextField $Reply 'tx_id'; $script:PendingOperation = 'Transfer tx_id=' + $TxId
    Write-Host "Gate accepted transfer. tx_id=$TxId"
    $Result = WaitTransfer $TxId $Plan.Amount
    if ($Result.status -ceq 'PENDING') { throw 'Transfer is still PENDING or unconfirmed. It was NOT reported as failed.' }
    $script:PendingOperation = $null
    if ($Result.status -ceq 'FAIL') { throw (Redact "Transfer FAIL: $($Result.fail_reason). No retry was attempted.") }
    Write-Host "Transfer SUCCESS. actual_receive=$($Result.actual_receive) USDT" -ForegroundColor Green
    if ((N $Result 'actual_receive') -lt ($Plan.Amount - $Plan.Fee)) { Write-Host 'WARNING: credited amount is below the estimate; check Gate fees.' -ForegroundColor Yellow }
    ShowBalances (Account)
}

$SecureSecret = $null; $Mutex = $null; $OwnsMutex = $false
$OldTls = [Net.ServicePointManager]::SecurityProtocol
try {
    [Net.ServicePointManager]::SecurityProtocol = $OldTls -bor [Net.SecurityProtocolType]::Tls12
    if ($MaxQuoteWorseningPercent -lt 0 -or $MaxQuoteWorseningPercent -ge 100 -or $StablecoinMaxLossPercent -lt 0 -or $StablecoinMaxLossPercent -ge 100) { throw 'Percentage limits must be >= 0 and < 100.' }
    Write-Host 'Gate CrossEx Cleaner v1.0.5'
    Write-Host "PowerShell $($PSVersionTable.PSVersion). No blockchain withdrawals."
    $script:ApiKey = (Read-Host 'Gate CrossEx API Key').Trim()
    $SecureSecret = Read-Host 'Gate CrossEx API Secret (hidden)' -AsSecureString
    $Bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureSecret)
    try { $script:ApiSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr) }
    if ([string]::IsNullOrWhiteSpace($script:ApiKey) -or [string]::IsNullOrWhiteSpace($script:ApiSecret)) { throw 'API Key/Secret is empty.' }
    if (-not $BalancesOnly) {
        $MutexName = 'GateCrossExCleaner_' + (Sha512 $script:ApiKey).Substring(0,32)
        $Mutex = New-Object Threading.Mutex($false,$MutexName)
        try { $OwnsMutex = $Mutex.WaitOne(0) }
        catch [Threading.AbandonedMutexException] { $OwnsMutex = $true; throw 'Previous cleaner ended unexpectedly. Check Gate before rerun.' }
        if (-not $OwnsMutex) { throw 'Another cleaner for this API key is running on this computer.' }
    }
    RunCleaner -ReadOnly ([bool]$BalancesOnly)
}
catch {
    if ($script:PendingOperation) {
        Write-Host (Redact "AMBIGUOUS: $script:PendingOperation. No automatic retry. Check Gate balances/history before any rerun.") -ForegroundColor Red
    }
    Write-Host (Redact "STOP: $($_.Exception.Message)") -ForegroundColor Red
    throw
}
finally {
    if ($OwnsMutex) { $Mutex.ReleaseMutex() }
    if ($null -ne $Mutex) { $Mutex.Dispose() }
    if ($null -ne $SecureSecret) { $SecureSecret.Dispose() }
    $script:ApiSecret = $null; $script:ApiKey = $null
    [Net.ServicePointManager]::SecurityProtocol = $OldTls
}
