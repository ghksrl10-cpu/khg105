param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('init','add-inbound','add-outbound','apply-inbound-file','status','set-qty')]
    [string]$Command,

    [string]$Model,
    [string]$Part,
    [int]$Qty,
    [string]$File,
    [string]$Note,
    [switch]$AllowNegative
)

$ErrorActionPreference = 'Stop'

# Paths
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$DataDir = Join-Path $Root 'data'
$InventoryCsv = Join-Path $DataDir 'inventory.csv'
$TxCsv = Join-Path $DataDir 'transactions.csv'

function Ensure-DataDir {
    if (-not (Test-Path $DataDir)) { New-Item -ItemType Directory -Path $DataDir | Out-Null }
}

function Ensure-InventoryFile {
    if (-not (Test-Path $InventoryCsv)) {
        Ensure-DataDir
        "model,part,qty" | Out-File -FilePath $InventoryCsv -Encoding utf8
    }
}

function Ensure-TransactionsFile {
    if (-not (Test-Path $TxCsv)) {
        Ensure-DataDir
        "timestamp,type,model,part,qty,note" | Out-File -FilePath $TxCsv -Encoding utf8
    }
}

function Get-Key([string]$m,[string]$p) { return "$m|$p" }

function Load-Inventory {
    Ensure-InventoryFile
    $map = @{}
    $rows = @()
    if (Test-Path $InventoryCsv -PathType Leaf) {
        $rows = Import-Csv -Path $InventoryCsv -Encoding UTF8
    }
    foreach ($r in $rows) {
        $key = Get-Key $r.model $r.part
        $map[$key] = [int]$r.qty
    }
    return $map
}

function Save-Inventory($map) {
    Ensure-InventoryFile
    $list = @()
    foreach ($k in $map.Keys) {
        $split = $k.Split('|',2)
        $list += [pscustomobject]@{ model=$split[0]; part=$split[1]; qty=$map[$k] }
    }
    $list | Sort-Object model, part | Export-Csv -Path $InventoryCsv -NoTypeInformation -Encoding UTF8
}

function Append-Transaction([string]$type,[string]$model,[string]$part,[int]$qty,[string]$note){
    Ensure-TransactionsFile
    $obj = [pscustomobject]@{
        timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss K')
        type      = $type
        model     = $model
        part      = $part
        qty       = $qty
        note      = $note
    }
    $obj | ConvertTo-Csv -NoTypeInformation | Select-Object -Skip 1 | Out-File -Append -FilePath $TxCsv -Encoding UTF8
}

function Add-Inbound([string]$model,[string]$part,[int]$qty,[string]$note){
    if (-not $model -or -not $part) { throw 'Model and Part are required.' }
    if ($qty -le 0) { throw 'Qty must be positive.' }
    $inv = Load-Inventory
    $key = Get-Key $model $part
    if (-not $inv.ContainsKey($key)) { $inv[$key] = 0 }
    $inv[$key] = [int]$inv[$key] + [int]$qty
    Save-Inventory $inv
    Append-Transaction 'inbound' $model $part $qty $note
}

function Add-Outbound([string]$model,[string]$part,[int]$qty,[string]$note,[switch]$allowNegative){
    if (-not $model -or -not $part) { throw 'Model and Part are required.' }
    if ($qty -le 0) { throw 'Qty must be positive.' }
    $inv = Load-Inventory
    $key = Get-Key $model $part
    if (-not $inv.ContainsKey($key)) { $inv[$key] = 0 }
    $newQty = [int]$inv[$key] - [int]$qty
    if (-not $allowNegative -and $newQty -lt 0) { throw "Outbound would make negative stock ($newQty). Use -AllowNegative to override." }
    $inv[$key] = $newQty
    Save-Inventory $inv
    Append-Transaction 'outbound' $model $part (-1 * $qty) $note
}

function Apply-Inbound-File([string]$path){
    if (-not (Test-Path $path)) { throw "File not found: $path" }
    $rows = Import-Csv -Path $path -Encoding UTF8
    foreach ($r in $rows) {
        $m = $r.model
        $p = $r.part
        $q = [int]$r.qty
        $n = $r.note
        Add-Inbound $m $p $q $n
    }
}

function Set-Qty([string]$model,[string]$part,[int]$qty,[string]$note){
    if (-not $model -or -not $part) { throw 'Model and Part are required.' }
    if ($qty -lt 0) { throw 'Qty must be >= 0.' }
    $inv = Load-Inventory
    $key = Get-Key $model $part
    $old = 0
    if ($inv.ContainsKey($key)) { $old = [int]$inv[$key] }
    $inv[$key] = $qty
    Save-Inventory $inv
    $delta = $qty - $old
    Append-Transaction 'adjust' $model $part $delta $note
}

function Show-Status([string]$model){
    $inv = Load-Inventory
    $rows = foreach ($k in $inv.Keys) {
        $split = $k.Split('|',2)
        [pscustomobject]@{ model=$split[0]; part=$split[1]; qty=$inv[$k] }
    }
    if ($model) { $rows = $rows | Where-Object { $_.model -eq $model } }
    if (-not $rows) { Write-Host 'No inventory'; return }
    $rows | Sort-Object model, part | Format-Table -AutoSize
    $totalByModel = $rows | Group-Object model | ForEach-Object { [pscustomobject]@{ model=$_.Name; total= ($_.Group | Measure-Object qty -Sum).Sum } }
    Write-Host ''
    Write-Host 'Totals by model:' -ForegroundColor Cyan
    $totalByModel | Sort-Object model | Format-Table -AutoSize
}

switch ($Command) {
    'init' { Ensure-InventoryFile; Ensure-TransactionsFile; Write-Host "Initialized data files at $DataDir"; break }
    'add-inbound' { Add-Inbound $Model $Part $Qty $Note; Write-Host 'Inbound added.'; break }
    'add-outbound' { Add-Outbound $Model $Part $Qty $Note $AllowNegative; Write-Host 'Outbound added.'; break }
    'apply-inbound-file' { Apply-Inbound-File $File; Write-Host 'Inbound file applied.'; break }
    'set-qty' { Set-Qty $Model $Part $Qty $Note; Write-Host 'Quantity set.'; break }
    'status' { Show-Status $Model; break }
    default { throw 'Unknown command' }
}
