[CmdletBinding()]
param(
    [switch]$BalancesOnly,
    [decimal]$MaxQuoteWorseningPercent = 1.0,
    [decimal]$StablecoinMaxLossPercent = 1.0,
    [int]$MaxCandidates = 40
)

# Gate CrossEx Cleaner
# Version: 1.0.4
# Windows PowerShell 5.1 / PowerShell 7+
# Converts supported CrossEx residual assets to CROSSEX USDT and transfers USDT to Gate SPOT.
# Does NOT perform blockchain withdrawals.

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -lt 5) {
    throw 'PowerShell 5.1 or newer is required.'
}

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

$ApiHost = 'https://api.gateio.ws'
$Prefix = '/api/v4'
$Inv = [Globalization.CultureInfo]::InvariantCulture
$SupportedVenues = @('BINANCE','OKX','GATE','BYBIT','KRAKEN','HYPERLIQUID')

function D($Value, [string]$Name = 'value') {
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        return [decimal]0
    }

    try {
        return [decimal]::Parse(
            [Convert]::ToString($Value, $Inv),
            [Globalization.NumberStyles]::Float,
            $Inv
        )
    }
    catch {
        throw "Gate returned invalid numeric ${Name}: '$Value'"
    }
}

function DS([decimal]$Value) {
    return $Value.ToString('0.############################', $Inv)
}

function Pct([decimal]$Value) {
    return $Value.ToString('0.0000', $Inv) + '%'
}

function UnixTime {
    return [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function Sha512([string]$Text) {
    $Hash = [Security.Cryptography.SHA512]::Create()
    try {
        return ([BitConverter]::ToString(
            $Hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        )).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $Hash.Dispose()
    }
}

function Hmac512([string]$Key, [string]$Text) {
    $Hmac = New-Object Security.Cryptography.HMACSHA512
    try {
        $Hmac.Key = [Text.Encoding]::UTF8.GetBytes($Key)
        return ([BitConverter]::ToString(
            $Hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))
        )).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $Hmac.Dispose()
    }
}

function HttpError($ErrorRecord) {
    $Parts = @()

    if ($ErrorRecord.Exception.Message) {
        $Parts += $ErrorRecord.Exception.Message
    }

    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        $Parts += $ErrorRecord.ErrorDetails.Message
    }

    try {
        $Response = $ErrorRecord.Exception.Response
        if ($null -ne $Response -and $null -ne $Response.GetResponseStream()) {
            $Reader = New-Object IO.StreamReader($Response.GetResponseStream())
            try {
                $Body = $Reader.ReadToEnd()
                if (-not [string]::IsNullOrWhiteSpace($Body)) {
                    $Parts += $Body
                }
            }
            finally {
                $Reader.Dispose()
            }
        }
    } catch {}

    if (-not $Parts.Count) {
        return 'Unknown HTTP error'
    }

    return ($Parts -join ' | ')
}

function Gate(
    [string]$Method,
    [string]$Path,
    [string]$Query = '',
    $Body = $null,
    [bool]$Signed = $true
) {
    $Method = $Method.ToUpperInvariant()

    if ($null -eq $Body) {
        $BodyText = ''
    }
    else {
        $BodyText = $Body | ConvertTo-Json -Compress -Depth 10
    }

    $Uri = "$ApiHost$Prefix$Path"
    if ($Query) {
        $Uri += "?$Query"
    }

    $Headers = @{ Accept = 'application/json' }

    if ($Signed) {
        $Timestamp = (UnixTime).ToString($Inv)
        $BodyHash = Sha512 $BodyText
        $SignText = $Method + "`n" + $Prefix + $Path + "`n" + $Query + "`n" + $BodyHash + "`n" + $Timestamp

        $Headers.KEY = $script:ApiKey
        $Headers.Timestamp = $Timestamp
        $Headers.SIGN = Hmac512 $script:ApiSecret $SignText
    }

    $Params = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $Headers
        ErrorAction = 'Stop'
    }

    if ($null -ne $Body) {
        $Params.Body = $BodyText
        $Params.ContentType = 'application/json'
    }

    try {
        return Invoke-RestMethod @Params
    }
    catch {
        throw "Gate API $Method $Path failed: $(HttpError $_)"
    }
}

function Account {
    return Gate GET '/crossex/accounts'
}

function OpenOrders {
    return @(Gate GET '/crossex/open_orders')
}

function FuturesPositions {
    return @(Gate GET '/crossex/positions')
}

function MarginPositions {
    return @(Gate GET '/crossex/margin_positions')
}

function Asset($AccountData, [string]$Venue, [string]$Coin) {
    return @($AccountData.assets) |
        Where-Object {
            ([string]$_.exchange_type).ToUpperInvariant() -eq $Venue.ToUpperInvariant() -and
            ([string]$_.coin).ToUpperInvariant() -eq $Coin.ToUpperInvariant()
        } |
        Select-Object -First 1
}

function NonZero($AccountData) {
    return @($AccountData.assets) |
        Where-Object {
            (D $_.balance 'balance') -ne 0 -or
            (D $_.available_balance 'available_balance') -ne 0
        }
}

function ShowBalances($AccountData) {
    $Items = @(NonZero $AccountData)

    Write-Host ''
    Write-Host 'Current non-zero CrossEx balances:' -ForegroundColor Cyan

    if (-not $Items.Count) {
        Write-Host '  No non-zero balances.'
        return
    }

    Write-Host ('{0,-15} {1,-10} {2,26} {3,26} {4,18}' -f 'ACCOUNT','COIN','BALANCE','AVAILABLE','LIABILITY')
    Write-Host ('-' * 100)

    foreach ($Item in $Items) {
        Write-Host ('{0,-15} {1,-10} {2,26} {3,26} {4,18}' -f `
            $Item.exchange_type,
            $Item.coin,
            $Item.balance,
            $Item.available_balance,
            $Item.liability
        )
    }
}

function UsdtAvailable($AccountData) {
    $Item = Asset $AccountData 'CROSSEX' 'USDT'
    if ($null -eq $Item) {
        return [decimal]0
    }

    return D $Item.available_balance 'CROSSEX USDT available_balance'
}

function RiskReasons($AccountData) {
    $Reasons = @()

    if ((D $AccountData.initial_margin 'initial_margin') -gt 0) {
        $Reasons += "initial_margin=$($AccountData.initial_margin)"
    }

    if ((D $AccountData.maintenance_margin 'maintenance_margin') -gt 0) {
        $Reasons += "maintenance_margin=$($AccountData.maintenance_margin)"
    }

    foreach ($Item in @($AccountData.assets)) {
        $Name = "$($Item.exchange_type) $($Item.coin)"

        foreach ($Field in @(
            'liability',
            'futures_initial_margin',
            'futures_maintenance_margin',
            'borrowing_initial_margin',
            'borrowing_maintenance_margin'
        )) {
            if ((D $Item.$Field $Field) -gt 0) {
                $Reasons += "$Field $Name=$($Item.$Field)"
            }
        }

        if ((D $Item.upnl 'upnl') -ne 0) {
            $Reasons += "upnl $Name=$($Item.upnl)"
        }
    }

    return $Reasons
}

function Candidates($AccountData) {
    $Accepted = @()
    $Skipped = @()

    foreach ($Item in @(NonZero $AccountData)) {
        $Venue = ([string]$Item.exchange_type).ToUpperInvariant()
        $Coin = ([string]$Item.coin).ToUpperInvariant()
        $Amount = D $Item.available_balance 'available_balance'

        if ($Amount -le 0 -or $Coin -eq 'USDT') {
            continue
        }

        $Reason = $null

        if ($Venue -eq 'CROSSEX') {
            $Reason = 'CROSSEX itself is not a Flash Swap venue'
        }
        elseif ($SupportedVenues -notcontains $Venue) {
            $Reason = 'Flash Swap venue is not supported by Gate'
        }

        if ($Reason) {
            $Skipped += [pscustomobject]@{
                Asset  = $Item
                Reason = $Reason
            }
        }
        else {
            $Accepted += $Item
        }
    }

    return [pscustomobject]@{
        Candidates = $Accepted
        Skipped    = $Skipped
    }
}

function Quote([string]$Venue, [string]$Coin, [decimal]$Amount) {
    $Result = Gate POST '/crossex/convert/quote' '' ([ordered]@{
        exchange_type = $Venue
        from_coin     = $Coin
        to_coin       = 'USDT'
        from_amount   = (DS $Amount)
    })

    if ([string]::IsNullOrWhiteSpace([string]$Result.quote_id)) {
        throw 'Quote response has no quote_id'
    }

    if (([string]$Result.to_coin).ToUpperInvariant() -ne 'USDT') {
        throw 'Quote target is not USDT'
    }

    if (([string]$Result.from_coin).ToUpperInvariant() -ne $Coin.ToUpperInvariant()) {
        throw 'Quote source coin does not match request'
    }

    if ((D $Result.from_amount 'quote.from_amount') -le 0 -or (D $Result.to_amount 'quote.to_amount') -le 0) {
        throw 'Quote returned non-positive amount'
    }

    return $Result
}

function Rate($QuoteData) {
    return (D $QuoteData.to_amount 'quote.to_amount') / (D $QuoteData.from_amount 'quote.from_amount')
}

function Worse([decimal]$PreviewRate, [decimal]$FreshRate) {
    if ($FreshRate -ge $PreviewRate) {
        return [decimal]0
    }

    return (($PreviewRate - $FreshRate) / $PreviewRate) * 100
}

function StableLoss([decimal]$EffectiveRate) {
    if ($EffectiveRate -ge 1) {
        return [decimal]0
    }

    return (1 - $EffectiveRate) * 100
}

function ExecuteQuote([string]$QuoteId) {
    return Gate POST '/crossex/convert/orders' '' ([ordered]@{
        quote_id = $QuoteId
    })
}

function WaitSettlement(
    [string]$Venue,
    [string]$Coin,
    [decimal]$SourceBefore,
    [decimal]$UsdtBefore,
    [int]$Seconds = 30
) {
    for ($i = 0; $i -lt $Seconds; $i++) {
        Start-Sleep -Seconds 1

        $CurrentAccount = Account
        $SourceAsset = Asset $CurrentAccount $Venue $Coin

        if ($null -eq $SourceAsset) {
            $SourceNow = [decimal]0
        }
        else {
            $SourceNow = D $SourceAsset.available_balance 'source available_balance'
        }

        $UsdtNow = UsdtAvailable $CurrentAccount

        if ($SourceNow -lt $SourceBefore -and $UsdtNow -gt $UsdtBefore) {
            return [pscustomobject]@{
                Settled  = $true
                SourceNow = $SourceNow
                UsdtNow  = $UsdtNow
            }
        }
    }

    return [pscustomobject]@{ Settled = $false }
}

function TransferRule {
    return @(Gate GET '/crossex/transfers/coin' 'coin=USDT' $null $false) |
        Where-Object { ([string]$_.coin).ToUpperInvariant() -eq 'USDT' } |
        Select-Object -First 1
}

function RoundDown([decimal]$Number, [int]$Precision) {
    if ($Precision -lt 0 -or $Precision -gt 28) {
        throw "Invalid precision: $Precision"
    }

    $Factor = [decimal]1
    for ($i = 0; $i -lt $Precision; $i++) {
        $Factor *= 10
    }

    return [decimal]::Floor($Number * $Factor) / $Factor
}

function Transfer([decimal]$Amount) {
    return Gate POST '/crossex/transfers' '' ([ordered]@{
        coin   = 'USDT'
        amount = (DS $Amount)
        from   = 'CROSSEX'
        to     = 'SPOT'
    })
}

function TransferRows([string]$TxId) {
    return @(Gate GET '/crossex/transfers' ("order_id={0}&limit=10" -f $TxId))
}

function WaitTransfer([string]$TxId, [int]$Seconds = 30) {
    $Last = $null

    for ($i = 0; $i -lt $Seconds; $i++) {
        foreach ($Row in @(TransferRows $TxId)) {
            if (([string]$Row.id) -eq $TxId) {
                $Last = $Row
                $Status = ([string]$Row.status).ToUpperInvariant()

                if (@('SUCCESS','FAIL') -contains $Status) {
                    return $Row
                }
            }
        }

        Start-Sleep -Seconds 1
    }

    return $Last
}

function Yes([string]$Question) {
    return ((Read-Host $Question).Trim() -ceq 'YES')
}

try {
    Write-Host ''
    Write-Host 'Gate CrossEx Cleaner v1.0.4' -ForegroundColor Cyan
    Write-Host "PowerShell $($PSVersionTable.PSVersion)"
    Write-Host 'This script does NOT perform blockchain withdrawals.'

    if ($MaxQuoteWorseningPercent -lt 0 -or $StablecoinMaxLossPercent -lt 0) {
        throw 'Percentage limits cannot be negative'
    }

    if ($MaxCandidates -lt 1 -or $MaxCandidates -gt 40) {
        throw 'MaxCandidates must be 1..40'
    }

    $script:ApiKey = (Read-Host 'Gate CrossEx API Key').Trim()
    $SecureSecret = Read-Host 'Gate CrossEx API Secret (hidden)' -AsSecureString
    $Bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureSecret)

    try {
        $script:ApiSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Bstr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Bstr)
    }

    if ([string]::IsNullOrWhiteSpace($script:ApiKey) -or [string]::IsNullOrWhiteSpace($script:ApiSecret)) {
        throw 'API Key/Secret is empty'
    }

    $CurrentAccount = Account
    ShowBalances $CurrentAccount

    if ($BalancesOnly) {
        Write-Host ''
        Write-Host 'Balances-only mode: no financial operations were performed.' -ForegroundColor Green
        return
    }

    if (([string]$CurrentAccount.account_mode).ToUpperInvariant() -ne 'CROSS_EXCHANGE') {
        throw "Full cleaner requires account_mode=CROSS_EXCHANGE; got '$($CurrentAccount.account_mode)'"
    }

    $Risks = @(RiskReasons $CurrentAccount)
    $Orders = @(OpenOrders)
    $Futures = @(FuturesPositions)
    $Margins = @(MarginPositions)

    if ($Orders.Count) {
        $Risks += "open_orders=$($Orders.Count)"
    }

    if ($Futures.Count) {
        $Risks += "futures_positions=$($Futures.Count)"
    }

    if ($Margins.Count) {
        $Risks += "margin_positions=$($Margins.Count)"
    }

    if ($Risks.Count) {
        Write-Host ''
        Write-Host 'STOP: active exposure/open orders detected:' -ForegroundColor Red
        $Risks | ForEach-Object { Write-Host "  - $_" }
        return
    }

    $CandidateResult = Candidates $CurrentAccount
    $CandidateList = @($CandidateResult.Candidates)
    $SkippedList = @($CandidateResult.Skipped)

    if ($SkippedList.Count) {
        Write-Host ''
        Write-Host 'Skipped before quote:' -ForegroundColor Yellow
        foreach ($Skipped in $SkippedList) {
            Write-Host "  $($Skipped.Asset.exchange_type) $($Skipped.Asset.coin): $($Skipped.Reason)"
        }
    }

    if ($CandidateList.Count -gt $MaxCandidates) {
        throw "Found $($CandidateList.Count) candidates; MaxCandidates=$MaxCandidates"
    }

    $Previews = @()

    if ($CandidateList.Count -and (Yes 'Request preview quotes now? Type YES')) {
        foreach ($Item in $CandidateList) {
            $Venue = ([string]$Item.exchange_type).ToUpperInvariant()
            $Coin = ([string]$Item.coin).ToUpperInvariant()
            $Amount = D $Item.available_balance 'available_balance'

            Write-Host -NoNewline "$Venue $Coin $(DS $Amount) -> USDT ... "

            try {
                $PreviewQuote = Quote $Venue $Coin $Amount
                $PreviewRate = Rate $PreviewQuote

                if (@('USDC','USD') -contains $Coin) {
                    $Loss = StableLoss $PreviewRate
                    if ($Loss -gt $StablecoinMaxLossPercent) {
                        Write-Host "SKIP: stablecoin loss $(Pct $Loss)" -ForegroundColor Yellow
                        continue
                    }
                }

                $Previews += [pscustomobject]@{
                    Venue = $Venue
                    Coin  = $Coin
                    Rate  = $PreviewRate
                }

                Write-Host "OK: $($PreviewQuote.to_amount) USDT" -ForegroundColor Green
            }
            catch {
                Write-Host "SKIP: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    $Ambiguous = $false

    if ($Previews.Count -and (Yes 'Execute accepted Flash Swaps? Type YES')) {
        foreach ($Preview in $Previews) {
            $FreshAccount = Account
            $Source = Asset $FreshAccount $Preview.Venue $Preview.Coin

            if ($null -eq $Source) {
                continue
            }

            $Amount = D $Source.available_balance 'current available_balance'
            if ($Amount -le 0) {
                continue
            }

            try {
                $FreshQuote = Quote $Preview.Venue $Preview.Coin $Amount
                $FreshRate = Rate $FreshQuote
            }
            catch {
                Write-Host "SKIP fresh quote: $($_.Exception.Message)" -ForegroundColor Yellow
                continue
            }

            $Worsening = Worse $Preview.Rate $FreshRate
            if ($Worsening -gt $MaxQuoteWorseningPercent) {
                Write-Host "SKIP $($Preview.Venue) $($Preview.Coin): quote worsened $(Pct $Worsening)" -ForegroundColor Yellow
                continue
            }

            if (@('USDC','USD') -contains $Preview.Coin) {
                $Loss = StableLoss $FreshRate
                if ($Loss -gt $StablecoinMaxLossPercent) {
                    Write-Host "SKIP $($Preview.Venue) $($Preview.Coin): stablecoin loss $(Pct $Loss)" -ForegroundColor Yellow
                    continue
                }
            }

            $UsdtBefore = UsdtAvailable $FreshAccount

            try {
                $Order = ExecuteQuote ([string]$FreshQuote.quote_id)
            }
            catch {
                Write-Host "AMBIGUOUS swap POST: $($_.Exception.Message)" -ForegroundColor Red
                $Ambiguous = $true
                break
            }

            $OrderId = [string]$Order.order_id
            if ([string]::IsNullOrWhiteSpace($OrderId)) {
                Write-Host 'AMBIGUOUS: Gate returned no order_id.' -ForegroundColor Red
                $Ambiguous = $true
                break
            }

            Write-Host "Gate accepted Flash Swap. order_id=$OrderId" -ForegroundColor Green

            $Settlement = WaitSettlement $Preview.Venue $Preview.Coin $Amount $UsdtBefore 30
            if (-not $Settlement.Settled) {
                Write-Host 'AMBIGUOUS: swap was accepted, but balance settlement was not confirmed in 30 seconds.' -ForegroundColor Red
                Write-Host 'Do not rerun the cleaner until you check the balances on Gate.' -ForegroundColor Red
                $Ambiguous = $true
                break
            }

            Write-Host "Settlement confirmed; CROSSEX USDT $(DS $UsdtBefore) -> $(DS $Settlement.UsdtNow)" -ForegroundColor Green
        }
    }

    $CurrentAccount = Account
    ShowBalances $CurrentAccount

    if ($Ambiguous) {
        Write-Host 'STOP: ambiguous Flash Swap state. Verify Gate manually before rerun.' -ForegroundColor Red
        return
    }

    $Usdt = UsdtAvailable $CurrentAccount
    if ($Usdt -le 0) {
        Write-Host 'No CROSSEX USDT available for SPOT transfer.'
        return
    }

    $Rule = TransferRule
    if ($null -eq $Rule) {
        throw 'No USDT transfer rule returned'
    }

    if ([int]$Rule.is_disabled -ne 0) {
        Write-Host 'USDT transfer is disabled by Gate.' -ForegroundColor Yellow
        return
    }

    $Precision = [int]$Rule.precision
    $Minimum = D $Rule.min_trans_amount 'min_trans_amount'
    $Fee = D $Rule.est_fee 'est_fee'
    $TransferAmount = RoundDown $Usdt $Precision

    $EstimatedReceive = $TransferAmount - $Fee
    if ($EstimatedReceive -lt 0) {
        $EstimatedReceive = [decimal]0
    }

    Write-Host ''
    Write-Host 'CROSSEX USDT -> SPOT:' -ForegroundColor Cyan
    Write-Host "  available=$(DS $Usdt)"
    Write-Host "  transfer amount=$(DS $TransferAmount)"
    Write-Host "  minimum=$(DS $Minimum)"
    Write-Host "  estimated fee=$(DS $Fee)"
    Write-Host "  estimated receive=$(DS $EstimatedReceive)"
    Write-Host "  precision=$Precision"

    if ($TransferAmount -le 0 -or $TransferAmount -lt $Minimum) {
        Write-Host 'Transfer amount is below the Gate minimum.'
        return
    }

    if (-not (Yes "Transfer $(DS $TransferAmount) USDT to SPOT? Type YES")) {
        Write-Host 'Transfer cancelled.'
        return
    }

    try {
        $TransferResult = Transfer $TransferAmount
    }
    catch {
        Write-Host "AMBIGUOUS transfer POST: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host 'Do not retry automatically. Check Gate first.' -ForegroundColor Red
        return
    }

    $TxId = [string]$TransferResult.tx_id
    if ([string]::IsNullOrWhiteSpace($TxId)) {
        Write-Host 'AMBIGUOUS: Gate returned no tx_id.' -ForegroundColor Red
        return
    }

    Write-Host "Gate accepted transfer. tx_id=$TxId" -ForegroundColor Green

    try {
        $TransferStatus = WaitTransfer $TxId 30

        if ($null -eq $TransferStatus) {
            Write-Host 'Transfer status timeout; do not retry automatically.' -ForegroundColor Yellow
        }
        elseif (([string]$TransferStatus.status).ToUpperInvariant() -eq 'SUCCESS') {
            Write-Host "Transfer SUCCESS. actual_receive=$($TransferStatus.actual_receive) USDT" -ForegroundColor Green
        }
        else {
            Write-Host "Transfer FAIL: $($TransferStatus.fail_reason)" -ForegroundColor Red
        }
    }
    catch {
        Write-Host "Status check failed: $($_.Exception.Message). Do not retry automatically." -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host 'Final CrossEx balances:' -ForegroundColor Cyan
    ShowBalances (Account)
}
catch {
    Write-Host ''
    Write-Host "STOP: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    $script:ApiSecret = $null
    $SecureSecret = $null
}
