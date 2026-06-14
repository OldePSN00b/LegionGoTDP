# LegionGoDevHelper.ps1
# Dot-source this in a new elevated Windows PowerShell 5.1 session:
# . .\LegionGoDevHelper.ps1

Set-StrictMode -Version 2.0

function Initialize-LegionWmiDevSession {
    $script:gz = Get-WmiObject -Namespace root\WMI -Class LENOVO_GAMEZONE_DATA -ErrorAction Stop
    $script:om = Get-WmiObject -Namespace root\WMI -Class LENOVO_OTHER_METHOD -ErrorAction Stop
    $script:fan = Get-WmiObject -Namespace root\WMI -Class LENOVO_FAN_METHOD -ErrorAction SilentlyContinue

    $script:gzClass = Get-CimClass -Namespace root\WMI -ClassName LENOVO_GAMEZONE_DATA -ErrorAction Stop
    $script:omClass = Get-CimClass -Namespace root\WMI -ClassName LENOVO_OTHER_METHOD -ErrorAction Stop
    $script:fanClass = Get-CimClass -Namespace root\WMI -ClassName LENOVO_FAN_METHOD -ErrorAction SilentlyContinue

    Write-Output "Legion WMI dev session initialized."
    Write-Output '$gz      = LENOVO_GAMEZONE_DATA'
    Write-Output '$om      = LENOVO_OTHER_METHOD'
    Write-Output '$fan     = LENOVO_FAN_METHOD'
    Write-Output '$gzClass = CIM class metadata'
    Write-Output '$omClass = CIM class metadata'
    Write-Output '$fanClass = CIM class metadata'
}

function Get-LegionWmiDevStatus {
    [pscustomobject]@{
        GameZoneDataLoaded = ($null -ne $script:gz)
        OtherMethodLoaded  = ($null -ne $script:om)
        FanMethodLoaded    = ($null -ne $script:fan)
        CurrentModeValue   = if ($script:gz) { [uint32]$script:gz.GetSmartFanMode().Data } else { $null }
        SmartFanSetting    = if ($script:gz) { [uint32]$script:gz.GetSmartFanSetting().Data } else { $null }
        FanCoolingStatus   = if ($script:gz) { [uint32]$script:gz.GetFanCoolingStatus().Data } else { $null }
        ThermalTableID     = if ($script:gz) { [uint32]$script:gz.GetThermalTableID().Data } else { $null }
    }
}

function Get-LegionGameZoneMethods {
    $script:gzClass.CimClassMethods |
        Select-Object Name |
        Sort-Object Name
}

function Get-LegionMethodParameters {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("GameZone", "Other", "Fan")]
        [string]$Class,

        [Parameter(Mandatory)]
        [string]$MethodName
    )

    $targetClass = switch ($Class) {
        "GameZone" { $script:gzClass }
        "Other"    { $script:omClass }
        "Fan"      { $script:fanClass }
    }

    $targetClass.CimClassMethods[$MethodName].Parameters |
        Format-Table Name, CimType, Qualifiers -Auto
}

function Get-LegionFanModeProbe {
    [pscustomobject]@{
        SmartFanMode     = [uint32]$script:gz.GetSmartFanMode().Data
        SmartFanSetting  = [uint32]$script:gz.GetSmartFanSetting().Data
        FanCoolingStatus = [uint32]$script:gz.GetFanCoolingStatus().Data
        ThermalTableID   = [uint32]$script:gz.GetThermalTableID().Data
    }
}

function Get-LegionCustomPowerProbe {
    $ids = @{
        TDP  = [uint32]16973568
        SPPT = [uint32]16908032
        FPPT = [uint32]17039104
    }

    foreach ($name in $ids.Keys) {
        [pscustomobject]@{
            Name  = $name
            ID    = $ids[$name]
            Value = $script:om.GetFeatureValue($ids[$name]).value
        }
    }
}

function Get-LegionExpandedFeatureTable {
    Get-WmiObject -Namespace root\WMI -Class LENOVO_CAPABILITY_DATA_01 |
        ForEach-Object {
            try {
                $current = $script:om.GetFeatureValue([uint32]$_.IDs).value
                $status = "OK"
            }
            catch {
                $current = $null
                $status = "ERR"
            }

            [pscustomobject]@{
                ID         = $_.IDs
                Capability = $_.Capability
                Current    = $current
                Default    = $_.DefaultValue
                Min        = $_.MinValue
                Max        = $_.MaxValue
                Step       = $_.Step
                Status     = $status
            }
        }
}

function Compare-LegionFeatureChange {
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

Initialize-LegionWmiDevSession