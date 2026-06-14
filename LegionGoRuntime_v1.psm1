# LegionGoRuntime_v1.psm1
# Original Lenovo Legion Go / Z1 Extreme WMI runtime helper
#
# Project scope:
#   Focus on replicating selected Legion Space flyout-style runtime controls.
#
# This module uses Lenovo's existing WMI provider exposed under root\WMI.
# It does NOT modify Legion Space databases, patch Lenovo software,
# alter binaries, or change saved Legion Space configuration files.
#
# Custom power values are runtime WMI overrides only.
# DAService or Legion Space may later reapply Lenovo's saved profile values.
#
# Best used from elevated Windows PowerShell 5.1.
# Use at your own risk.

Set-StrictMode -Version 2.0

#region Private/Internal Maps

$script:LegionCustomPowerMap = @{
    TDP  = [uint32]16973568
    SPL  = [uint32]16973568
    SPPT = [uint32]16908032
    FPPT = [uint32]17039104
}

#endregion Private/Internal Maps

#region Private/Internal Helpers

function Get-LegionGameZoneData {
    <#
    .SYNOPSIS
        Gets Lenovo GameZone WMI data object.
    #>

    Get-WmiObject -Namespace root\WMI -Class LENOVO_GAMEZONE_DATA -ErrorAction Stop
}

function Get-LegionOtherMethod {
    <#
    .SYNOPSIS
        Gets Lenovo Other Method WMI object.
    #>

    Get-WmiObject -Namespace root\WMI -Class LENOVO_OTHER_METHOD -ErrorAction Stop
}

function Invoke-LegionGameZoneGetter {
    <#
    .SYNOPSIS
        Invokes a parameterless LENOVO_GAMEZONE_DATA getter and returns its Data value when present.
    #>

    param(
        [Parameter(Mandatory)]
        [object]$GameZoneData,

        [Parameter(Mandatory)]
        [string]$MethodName
    )

    try {
        $result = $GameZoneData.$MethodName()

        if ($result.PSObject.Properties.Name -contains "Data") {
            return $result.Data
        }

        return $result
    }
    catch {
        return $null
    }
}

#endregion Private/Internal Helpers

#region Runtime/User Functions

function ConvertFrom-LegionThermalMode {
    <#
    .SYNOPSIS
        Converts Lenovo thermal mode numeric values to readable names.

    .DESCRIPTION
        Confirmed values on Original Legion Go:
            1   Quiet
            2   Balanced
            3   Performance
            255 Custom
    #>

    param(
        [Parameter(Mandatory)]
        [uint32]$ModeValue
    )

    switch ($ModeValue) {
        1   { "Quiet" }
        2   { "Balanced" }
        3   { "Performance" }
        255 { "Custom" }
        default { "Unknown ($ModeValue)" }
    }
}

function ConvertTo-LegionThermalMode {
    <#
    .SYNOPSIS
        Converts a thermal mode name to Lenovo's numeric thermal mode value.
    #>

    param(
        [Parameter(Mandatory)]
        [ValidateSet("Quiet", "Balanced", "Performance", "Custom")]
        [string]$ModeName
    )

    switch ($ModeName) {
        "Quiet"       { [uint32]1 }
        "Balanced"    { [uint32]2 }
        "Performance" { [uint32]3 }
        "Custom"      { [uint32]255 }
    }
}

function Get-LegionRuntimeStatus {
    <#
    .SYNOPSIS
        Reports runtime environment status for this module.

    .DESCRIPTION
        This function intentionally reports that the module does not modify Lenovo databases,
        services, or saved Legion Space profiles.
    #>

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
    <#
    .SYNOPSIS
        Gets the active Lenovo thermal mode.
    #>

    $gameZoneData = Get-LegionGameZoneData
    $modeValue = [uint32]$gameZoneData.GetSmartFanMode().Data

    [pscustomobject]@{
        ModeValue = $modeValue
        ModeName  = ConvertFrom-LegionThermalMode -ModeValue $modeValue
    }
}

function Set-LegionThermalMode {
    <#
    .SYNOPSIS
        Sets the active Lenovo thermal mode.

    .EXAMPLE
        Set-LegionThermalMode -ModeName Performance
    #>

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

function Get-LegionCustomPowerRuntime {
    <#
    .SYNOPSIS
        Gets runtime Custom power values exposed by Lenovo WMI.

    .DESCRIPTION
        These values are runtime WMI values, not saved Legion Space profile settings.
        DAService or Legion Space may overwrite them from saved profile data.
    #>

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
    <#
    .SYNOPSIS
        Sets one runtime Custom power value.

    .DESCRIPTION
        This applies a runtime WMI override only.
        It does not modify saved Legion Space profiles or databases.
        Custom power writes require Custom thermal mode.

    .EXAMPLE
        Set-LegionCustomPowerRuntime -Name TDP -Watts 20
    #>

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
    <#
    .SYNOPSIS
        Sets runtime Custom TDP, SPPT, and FPPT values together.

    .DESCRIPTION
        This applies runtime WMI overrides only.
        It does not modify saved Legion Space profiles or databases.

    .EXAMPLE
        Set-LegionCustomPowerRuntimeProfile -TDP 20 -SPPT 23 -FPPT 24
    #>

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

function Repair-LegionCustomPowerRuntimeProfile {
    <#
    .SYNOPSIS
        Reapplies runtime Custom power values only when current values differ.

    .DESCRIPTION
        This is intentionally manual and non-looping.
        It does not fight DAService or Legion Space in the background.
    #>

    param(
        [Parameter(Mandatory)]
        [uint32]$TDP,

        [Parameter(Mandatory)]
        [uint32]$SPPT,

        [Parameter(Mandatory)]
        [uint32]$FPPT
    )

    $current = Get-LegionCustomPowerRuntime

    $currentTdp = ($current | Where-Object { $_.Name -eq "TDP" }).Current
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

function Get-LegionFanStatus {
    <#
    .SYNOPSIS
        Gets basic Lenovo fan/thermal state values exposed through GameZone WMI.
    #>

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

function Get-LegionSensorStatus {
    <#
    .SYNOPSIS
        Gets basic sensors exposed by Lenovo GameZone WMI.
    #>

    $gameZoneData = Get-LegionGameZoneData

    [pscustomobject]@{
        CPUTemp                 = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "GetCPUTemp"
        GPUTemp                 = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "GetGPUTemp"
        IRTemp                  = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "GetIRTemp"
        FanCount                = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "GetFanCount"
        Fan1Speed               = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "GetFan1Speed"
        Fan2Speed               = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "GetFan2Speed"
        FanMaxSpeed             = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "GetFanMaxSpeed"
        TriggerTemperatureValue = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "GetTriggerTemperatureValue"
        CpuFrequency            = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "GetCpuFrequency"
    }
}

#endregion Runtime/User Functions

#region Thermal Event Monitoring

function Start-LegionThermalWatcher {
    <#
    .SYNOPSIS
        Starts a WMI event watcher for Lenovo thermal mode changes.
    #>

    Unregister-Event -SourceIdentifier LegionThermalMode -ErrorAction SilentlyContinue
    Remove-Event -SourceIdentifier LegionThermalMode -ErrorAction SilentlyContinue

    Register-WmiEvent `
        -Namespace root\WMI `
        -Query "SELECT * FROM LENOVO_GAMEZONE_THERMAL_MODE_EVENT" `
        -SourceIdentifier LegionThermalMode | Out-Null

    Write-Output "Legion thermal mode watcher started."
}

function Stop-LegionThermalWatcher {
    <#
    .SYNOPSIS
        Stops the WMI event watcher for Lenovo thermal mode changes.
    #>

    Unregister-Event -SourceIdentifier LegionThermalMode -ErrorAction SilentlyContinue
    Remove-Event -SourceIdentifier LegionThermalMode -ErrorAction SilentlyContinue

    Write-Output "Legion thermal mode watcher stopped."
}

function Clear-LegionThermalEvents {
    <#
    .SYNOPSIS
        Clears queued Lenovo thermal mode events.
    #>

    Remove-Event -SourceIdentifier LegionThermalMode -ErrorAction SilentlyContinue
    Write-Output "Legion thermal mode event queue cleared."
}

function Get-LegionLastThermalEvent {
    <#
    .SYNOPSIS
        Gets the most recent queued Lenovo thermal mode event.
    #>

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

#endregion Thermal Event Monitoring

#region Diagnostics/Research Functions

function Test-LegionSpaceGuiRunning {
    <#
    .SYNOPSIS
        Returns true if a Legion Space GUI process appears to be running.
    #>

    $legionSpaceProcesses = Get-Process -ErrorAction SilentlyContinue |
        Where-Object {
            $_.ProcessName -like "*LegionSpace*" -or
            $_.ProcessName -like "*Legion*Space*"
        }

    return [bool]$legionSpaceProcesses
}

function Get-LegionFeatureSupportStatus {
    <#
    .SYNOPSIS
        Gets Lenovo GameZone feature support flags.
    #>

    $gameZoneData = Get-LegionGameZoneData

    [pscustomobject]@{
        FanCooling      = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "IsSupportFanCooling"
        SmartFan        = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "IsSupportSmartFan"
        CpuOC           = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "IsSupportCpuOC"
        GpuOC           = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "IsSupportGpuOC"
        BIOSOC          = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "IsBIOSSupportOC"
        WaterCooling    = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "IsSupportWaterCooling"
        LightingFeature = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "IsSupportLightingFeature"
        DisableWinKey   = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "IsSupportDisableWinKey"
        DisableTouchpad = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "IsSupportDisableTP"
        GSync           = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "IsSupportGSync"
        OverDrive       = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "IsSupportOD"
        IGpuMode        = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "IsSupportIGPUMode"
    }
}

function Get-LegionFanControlProbe {
    <#
    .SYNOPSIS
        Gets a compact fan/thermal probe for before/after comparisons.
    #>

    $gameZoneData = Get-LegionGameZoneData
    $modeValue = [uint32]$gameZoneData.GetSmartFanMode().Data

    [pscustomobject]@{
        ThermalModeValue = $modeValue
        ThermalModeName  = ConvertFrom-LegionThermalMode -ModeValue $modeValue
        SmartFanSetting  = [uint32]$gameZoneData.GetSmartFanSetting().Data
        FanCoolingStatus = [uint32]$gameZoneData.GetFanCoolingStatus().Data
        ThermalTableID   = [uint32]$gameZoneData.GetThermalTableID().Data
        Fan1Speed        = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "GetFan1Speed"
        Fan2Speed        = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "GetFan2Speed"
        FanMaxSpeed      = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "GetFanMaxSpeed"
        CPUTemp          = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "GetCPUTemp"
        GPUTemp          = Invoke-LegionGameZoneGetter -GameZoneData $gameZoneData -MethodName "GetGPUTemp"
    }
}

function Compare-LegionFanControlProbe {
    <#
    .SYNOPSIS
        Compares two fan control probe snapshots.
    #>

    param(
        [Parameter(Mandatory)]
        [object]$Before,

        [Parameter(Mandatory)]
        [object]$After
    )

    $properties = @(
        "ThermalModeValue",
        "ThermalModeName",
        "SmartFanSetting",
        "FanCoolingStatus",
        "ThermalTableID",
        "Fan1Speed",
        "Fan2Speed",
        "FanMaxSpeed",
        "CPUTemp",
        "GPUTemp"
    )

    foreach ($propertyName in $properties) {
        [pscustomobject]@{
            Property = $propertyName
            Before   = $Before.$propertyName
            After    = $After.$propertyName
            Changed  = ($Before.$propertyName -ne $After.$propertyName)
        }
    }
}

function Get-LegionFanCurves {
    <#
    .SYNOPSIS
        Gets Lenovo fan curve definitions exposed by LENOVO_FAN_TABLE_DATA.

    .DESCRIPTION
        This is diagnostic/read-only. It returns static fan curve definitions by mode.
    #>

    Get-CimInstance -Namespace root\WMI -ClassName LENOVO_FAN_TABLE_DATA -ErrorAction Stop |
        ForEach-Object {
            [pscustomobject]@{
                Mode                    = $_.Mode
                FanId                   = $_.Fan_Id
                SensorId                = $_.Sensor_ID
                CurrentFanMaxSpeed      = $_.CurrentFanMaxSpeed
                CurrentFanMinSpeed      = $_.CurrentFanMinSpeed
                DesignMaxFanSpeedNumber = $_.DesignMaxFanSpeedNumber
                FanSpeedStep            = $_.FanSpeedStep
                FanTable                = ($_.FanTable_Data -join ",")
                SensorTable             = ($_.SensorTable_Data -join ",")
                InstanceName            = $_.InstanceName
            }
        }
}

function Get-LegionFanTable {
    <#
    .SYNOPSIS
        Probes LENOVO_FAN_METHOD.Fan_Get_Table across common FanID/SensorID values.
    #>

    $fanMethod = Get-WmiObject -Namespace root\WMI -Class LENOVO_FAN_METHOD -ErrorAction Stop

    foreach ($fanId in 0..3) {
        foreach ($sensorId in 0..3) {
            try {
                $result = $fanMethod.Fan_Get_Table([byte]$fanId, [byte]$sensorId)

                [pscustomobject]@{
                    FanID           = $fanId
                    SensorID        = $sensorId
                    FanTableSize    = $result.FanTableSize
                    SensorTableSize = $result.SensorTableSize
                    FanTable        = ($result.FanTable -join ",")
                    SensorTable     = ($result.SensorTable -join ",")
                    Status          = "OK"
                }
            }
            catch {
                [pscustomobject]@{
                    FanID           = $fanId
                    SensorID        = $sensorId
                    FanTableSize    = $null
                    SensorTableSize = $null
                    FanTable        = $null
                    SensorTable     = $null
                    Status          = "ERR"
                }
            }
        }
    }
}

function Get-LegionExpandedFeatureTable {
    <#
    .SYNOPSIS
        Gets expanded Lenovo capability/feature values from LENOVO_CAPABILITY_DATA_01.
    #>

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

function Compare-LegionFeatureChange {
    <#
    .SYNOPSIS
        Compares two expanded feature table snapshots.
    #>

    param(
        [Parameter(Mandatory)]
        [object[]]$Before,

        [Parameter(Mandatory)]
        [object[]]$After
    )

    Compare-Object $Before $After -Property ID,Current -PassThru |
        Sort-Object ID |
        Format-Table ID,Capability,Current,Default,Min,Max,Step,Status -Auto
}

function Get-LegionGameZoneMethods {
    <#
    .SYNOPSIS
        Lists LENOVO_GAMEZONE_DATA methods and categorizes them.
    #>

    $gameZoneClass = Get-CimClass -Namespace root\WMI -ClassName LENOVO_GAMEZONE_DATA -ErrorAction Stop

    $gameZoneClass.CimClassMethods |
        Sort-Object Name |
        ForEach-Object {
            [pscustomobject]@{
                Method = $_.Name
                Type   = if ($_.Name -like "Get*") {
                    "Getter"
                }
                elseif ($_.Name -like "Set*") {
                    "Setter"
                }
                elseif ($_.Name -like "Is*") {
                    "Support"
                }
                elseif ($_.Name -like "Notify*") {
                    "Notify"
                }
                else {
                    "Other"
                }
            }
        }
}

function Get-LegionGameZoneMethodDetails {
    <#
    .SYNOPSIS
        Lists LENOVO_GAMEZONE_DATA methods and their parameter names.
    #>

    $gameZoneClass = Get-CimClass -Namespace root\WMI -ClassName LENOVO_GAMEZONE_DATA -ErrorAction Stop

    foreach ($method in ($gameZoneClass.CimClassMethods | Sort-Object Name)) {
        [pscustomobject]@{
            Method     = $method.Name
            Parameters = ($method.Parameters.Name -join ", ")
            Count      = @($method.Parameters).Count
        }
    }
}

function Get-LegionGameZoneMethodResults {
    <#
    .SYNOPSIS
        Invokes parameterless LENOVO_GAMEZONE_DATA methods for diagnostics.

    .DESCRIPTION
        Setter methods are expected to return ERR because they require parameters.
    #>

    $gameZoneData = Get-LegionGameZoneData

    foreach ($method in ($gameZoneData | Get-Member -MemberType Method | Select-Object -ExpandProperty Name | Sort-Object)) {
        try {
            $result = $gameZoneData.$method()

            [pscustomobject]@{
                Method = $method
                Result = if ($result.PSObject.Properties.Name -contains "Data") {
                    $result.Data
                }
                else {
                    $result
                }
                Status = "OK"
            }
        }
        catch {
            [pscustomobject]@{
                Method = $method
                Result = $null
                Status = "ERR"
            }
        }
    }
}

function Export-LegionFeatureTable {
    <#
    .SYNOPSIS
        Exports expanded Lenovo feature table values to JSON.
    #>

    param(
        [string]$Path = "$env:USERPROFILE\Desktop\LegionGoFeatureTable.json"
    )

    Get-LegionExpandedFeatureTable |
        ConvertTo-Json -Depth 4 |
        Set-Content -Path $Path -Encoding UTF8

    Write-Output "Legion feature table exported to $Path"
}

#endregion Diagnostics/Research Functions

Export-ModuleMember -Function `
    ConvertFrom-LegionThermalMode, `
    ConvertTo-LegionThermalMode, `
    Get-LegionRuntimeStatus, `
    Get-LegionThermalMode, `
    Set-LegionThermalMode, `
    Get-LegionCustomPowerRuntime, `
    Set-LegionCustomPowerRuntime, `
    Set-LegionCustomPowerRuntimeProfile, `
    Repair-LegionCustomPowerRuntimeProfile, `
    Get-LegionFanStatus, `
    Get-LegionSensorStatus, `
    Start-LegionThermalWatcher, `
    Stop-LegionThermalWatcher, `
    Clear-LegionThermalEvents, `
    Get-LegionLastThermalEvent, `
    Test-LegionSpaceGuiRunning, `
    Get-LegionFeatureSupportStatus, `
    Get-LegionFanControlProbe, `
    Compare-LegionFanControlProbe, `
    Get-LegionFanCurves, `
    Get-LegionFanTable, `
    Get-LegionExpandedFeatureTable, `
    Compare-LegionFeatureChange, `
    Get-LegionGameZoneMethods, `
    Get-LegionGameZoneMethodDetails, `
    Get-LegionGameZoneMethodResults, `
    Export-LegionFeatureTable
