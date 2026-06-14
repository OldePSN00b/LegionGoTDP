# LegionGoRuntime.psm1
# Original Lenovo Legion Go / Z1 Extreme WMI runtime helper
#
# This module uses Lenovo's existing WMI provider exposed under root\WMI.
# It does NOT modify Legion Space databases, patch Lenovo software,
# alter binaries, or change saved Legion Space configuration files.
#
# Custom power values are runtime WMI overrides only.
# DAService or Legion Space may later reapply Lenovo's saved profile values.
#
# Use at your own risk.

Set-StrictMode -Version 2.0

$script:LegionCustomPowerMap = @{
    TDP  = [uint32]16973568
    SPL  = [uint32]16973568
    SPPT = [uint32]16908032
    FPPT = [uint32]17039104
}

function Get-LegionGameZoneData {
    Get-WmiObject -Namespace root\WMI -Class LENOVO_GAMEZONE_DATA -ErrorAction Stop
}

function Get-LegionOtherMethod {
    Get-WmiObject -Namespace root\WMI -Class LENOVO_OTHER_METHOD -ErrorAction Stop
}

function ConvertFrom-LegionThermalMode {
    param(
        [Parameter(Mandatory)]
        [uint32]$ModeValue
    )

    switch ($ModeValue) {
        1 { "Quiet" }
        2 { "Balanced" }
        3 { "Performance" }
        255 { "Custom" }
        default { "Unknown ($ModeValue)" }
    }
}

function ConvertTo-LegionThermalMode {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Quiet", "Balanced", "Performance", "Custom")]
        [string]$ModeName
    )

    switch ($ModeName) {
        "Quiet" { [uint32]1 }
        "Balanced" { [uint32]2 }
        "Performance" { [uint32]3 }
        "Custom" { [uint32]255 }
    }
}

function Get-LegionRuntimeStatus {
    $daService = Get-Service -Name DAService -ErrorAction SilentlyContinue

    $legionSpaceProcesses = Get-Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessName -like "*LegionSpace*" -or
        $_.ProcessName -like "*Legion*Space*"
    }

    [pscustomobject]@{
        DAServiceStatus       = if ($daService) { $daService.Status } else { "Not found" }
        LegionSpaceGuiRunning = [bool]$legionSpaceProcesses
        PersistenceModel      = "Runtime WMI override only"
        DatabaseModification  = "None"
        ServiceModification   = "None"
    }
}

function Get-LegionThermalMode {
    $gameZoneData = Get-LegionGameZoneData
    $modeValue = [uint32]$gameZoneData.GetSmartFanMode().Data

    [pscustomobject]@{
        ModeValue = $modeValue
        ModeName  = ConvertFrom-LegionThermalMode -ModeValue $modeValue
    }
}

function Set-LegionThermalMode {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Quiet", "Balanced", "Performance", "Custom")]
        [string]$ModeName
    )

    $requestedValue = ConvertTo-LegionThermalMode -ModeName $ModeName
    $gameZoneData = Get-LegionGameZoneData

    $gameZoneData.SetSmartFanMode($requestedValue) | Out-Null
    Start-Sleep -Milliseconds 500

    $actualValue = [uint32]$gameZoneData.GetSmartFanMode().Data

    [pscustomobject]@{
        RequestedName  = $ModeName
        RequestedValue = $requestedValue
        ActualName     = ConvertFrom-LegionThermalMode -ModeValue $actualValue
        ActualValue    = $actualValue
        Success        = ($actualValue -eq $requestedValue)
    }
}

function Get-LegionFanStatus {
    $gameZoneData = Get-LegionGameZoneData
    $smartFanMode = [uint32]$gameZoneData.GetSmartFanMode().Data

    [pscustomobject]@{
        SmartFanMode     = $smartFanMode
        SmartFanModeName = ConvertFrom-LegionThermalMode -ModeValue $smartFanMode
        SmartFanSetting  = [uint32]$gameZoneData.GetSmartFanSetting().Data
        FanCoolingStatus = [uint32]$gameZoneData.GetFanCoolingStatus().Data
        ThermalTableID   = [uint32]$gameZoneData.GetThermalTableID().Data
    }
}

function Get-LegionCustomPowerRuntime {
    $otherMethod = Get-LegionOtherMethod

    foreach ($powerLimitName in "TDP", "SPPT", "FPPT") {
        $featureId = $script:LegionCustomPowerMap[$powerLimitName]

        try {
            $currentValue = $otherMethod.GetFeatureValue($featureId).value
            $status = "OK"
        }
        catch {
            $currentValue = $null
            $status = $_.Exception.Message
        }

        [pscustomobject]@{
            Name    = $powerLimitName
            ID      = $featureId
            Current = $currentValue
            Status  = $status
        }
    }
}

function Set-LegionCustomPowerRuntime {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("TDP", "SPL", "SPPT", "FPPT")]
        [string]$Name,

        [Parameter(Mandatory)]
        [uint32]$Watts
    )

    $featureId = $script:LegionCustomPowerMap[$Name]

    if (-not $featureId) {
        throw "Unknown custom power limit '$Name'."
    }

    $gameZoneData = Get-LegionGameZoneData
    $currentMode = [uint32]$gameZoneData.GetSmartFanMode().Data

    if ($currentMode -ne 255) {
        Write-Output "Switching to Custom thermal mode because Custom power runtime overrides require Custom mode."
        $gameZoneData.SetSmartFanMode([uint32]255) | Out-Null
        Start-Sleep -Milliseconds 750
    }

    $otherMethod = Get-LegionOtherMethod
    $beforeValue = $otherMethod.GetFeatureValue($featureId).value

    $otherMethod.SetFeatureValue($featureId, $Watts) | Out-Null
    Start-Sleep -Milliseconds 500

    $afterValue = $otherMethod.GetFeatureValue($featureId).value

    [pscustomobject]@{
        Name      = $Name
        ID        = $featureId
        Before    = $beforeValue
        Requested = $Watts
        After     = $afterValue
        Success   = ($afterValue -eq $Watts)
        Note      = "Runtime WMI override only. This does not modify saved Legion Space profiles and may be overwritten by DAService or Legion Space."
    }
}

function Set-LegionCustomPowerRuntimeProfile {
    param(
        [Parameter(Mandatory)]
        [uint32]$TDP,

        [Parameter(Mandatory)]
        [uint32]$SPPT,

        [Parameter(Mandatory)]
        [uint32]$FPPT
    )

    Set-LegionThermalMode -ModeName Custom | Out-Null
    Start-Sleep -Milliseconds 750

    Set-LegionCustomPowerRuntime -Name TDP  -Watts $TDP  | Out-Null
    Set-LegionCustomPowerRuntime -Name SPPT -Watts $SPPT | Out-Null
    Set-LegionCustomPowerRuntime -Name FPPT -Watts $FPPT | Out-Null

    Get-LegionCustomPowerRuntime
}

function Get-LegionExpandedFeatureTable {
    $otherMethod = Get-LegionOtherMethod

    Get-WmiObject -Namespace root\WMI -Class LENOVO_CAPABILITY_DATA_01 -ErrorAction Stop |
    ForEach-Object {
        try {
            $currentValue = $otherMethod.GetFeatureValue([uint32]$_.IDs).value
            $status = "OK"
        }
        catch {
            $currentValue = $null
            $status = "ERR"
        }

        [pscustomobject]@{
            ID         = $_.IDs
            Capability = $_.Capability
            Current    = $currentValue
            Default    = $_.DefaultValue
            Min        = $_.MinValue
            Max        = $_.MaxValue
            Step       = $_.Step
            Status     = $status
        }
    }
}

function Start-LegionThermalWatcher {
    Unregister-Event -SourceIdentifier LegionThermalMode -ErrorAction SilentlyContinue
    Remove-Event -SourceIdentifier LegionThermalMode -ErrorAction SilentlyContinue

    Register-WmiEvent `
        -Namespace root\WMI `
        -Query "SELECT * FROM LENOVO_GAMEZONE_THERMAL_MODE_EVENT" `
        -SourceIdentifier LegionThermalMode | Out-Null

    Write-Output "Legion thermal mode watcher started."
}

function Stop-LegionThermalWatcher {
    Unregister-Event -SourceIdentifier LegionThermalMode -ErrorAction SilentlyContinue
    Remove-Event -SourceIdentifier LegionThermalMode -ErrorAction SilentlyContinue

    Write-Output "Legion thermal mode watcher stopped."
}

function Clear-LegionThermalEvents {
    Remove-Event -SourceIdentifier LegionThermalMode -ErrorAction SilentlyContinue
    Write-Output "Legion thermal mode event queue cleared."
}

function Get-LegionLastThermalEvent {
    $thermalEvent = Get-Event -SourceIdentifier LegionThermalMode -ErrorAction SilentlyContinue |
    Select-Object -Last 1

    if (-not $thermalEvent) {
        Write-Output "No Legion thermal mode events are currently queued."
        return
    }

    $modeValue = [uint32]$thermalEvent.SourceEventArgs.NewEvent.mode

    [pscustomobject]@{
        TimeGenerated = $thermalEvent.TimeGenerated
        ModeValue     = $modeValue
        ModeName      = ConvertFrom-LegionThermalMode -ModeValue $modeValue
        InstanceName  = $thermalEvent.SourceEventArgs.NewEvent.InstanceName
    }
}

function Export-LegionFeatureTable {
    param(
        [string]$Path = "$env:USERPROFILE\Desktop\LegionGoFeatureTable.json"
    )

    Get-LegionExpandedFeatureTable |
    ConvertTo-Json -Depth 4 |
    Set-Content -Path $Path -Encoding UTF8

    Write-Output "Legion feature table exported to $Path"
}

function Test-LegionSpaceGuiRunning {
    $legionSpaceProcesses = Get-Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.ProcessName -like "*LegionSpace*" -or
        $_.ProcessName -like "*Legion*Space*"
    }

    return [bool]$legionSpaceProcesses
}

function Repair-LegionCustomPowerRuntimeProfile {
    param(
        [Parameter(Mandatory)]
        [uint32]$TDP,

        [Parameter(Mandatory)]
        [uint32]$SPPT,

        [Parameter(Mandatory)]
        [uint32]$FPPT
    )

    $current = Get-LegionCustomPowerRuntime

    $currentTdp  = ($current | Where-Object { $_.Name -eq "TDP" }).Current
    $currentSppt = ($current | Where-Object { $_.Name -eq "SPPT" }).Current
    $currentFppt = ($current | Where-Object { $_.Name -eq "FPPT" }).Current

    if (
        $currentTdp -eq $TDP -and
        $currentSppt -eq $SPPT -and
        $currentFppt -eq $FPPT
    ) {
        Write-Output "Runtime Custom power values already match requested values."
        return
    }

    Set-LegionCustomPowerRuntimeProfile -TDP $TDP -SPPT $SPPT -FPPT $FPPT
}

Export-ModuleMember -Function `
    ConvertFrom-LegionThermalMode, `
    ConvertTo-LegionThermalMode, `
    Get-LegionRuntimeStatus, `
    Get-LegionThermalMode, `
    Set-LegionThermalMode, `
    Get-LegionFanStatus, `
    Get-LegionCustomPowerRuntime, `
    Set-LegionCustomPowerRuntime, `
    Set-LegionCustomPowerRuntimeProfile, `
    Get-LegionExpandedFeatureTable, `
    Start-LegionThermalWatcher, `
    Stop-LegionThermalWatcher, `
    Clear-LegionThermalEvents, `
    Get-LegionLastThermalEvent, `
    Export-LegionFeatureTable, `
    Test-LegionSpaceGuiRunning, `
    Repair-LegionCustomPowerRuntimeProfile
