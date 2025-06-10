#Requires -Modules Az.Network

<#
.SYNOPSIS
    Associates subnets with region-specific NSGs across multiple Azure regions
.DESCRIPTION
    This script iterates through all VNets in a subscription and associates subnets 
    with their respective regional NSGs. It skips subnets that already have NSGs associated.
.PARAMETER SubscriptionId
    The Azure subscription ID to process
.PARAMETER WhatIf
    Preview what changes would be made without actually applying them
.PARAMETER Force
    Skip confirmation prompts
.PARAMETER ExcludeSubnets
    Array of subnet names to exclude from processing (e.g., GatewaySubnet, AzureFirewallSubnet)
.EXAMPLE
    .\Associate-RegionalNSGs.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012"
.EXAMPLE
    .\Associate-RegionalNSGs.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" -WhatIf
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    
    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,
    
    [Parameter(Mandatory = $false)]
    [switch]$Force,
    
    [Parameter(Mandatory = $false)]
    [string[]]$ExcludeSubnets = @("GatewaySubnet", "AzureFirewallSubnet", "AzureBastionSubnet", "RouteServerSubnet")
)

#region Variables - Define NSGs for each region
Write-Host "=== Multi-Region NSG Association Script ===" -ForegroundColor Cyan
Write-Host "Started at: $(Get-Date)" -ForegroundColor Gray

# Define NSG variables for each region
$RegionalNSGs = @{
    "East US" = @{
        ResourceGroupName = "rg-security-eastus"
        NSGName = "nsg-eastus-default"
    }
    "West US" = @{
        ResourceGroupName = "rg-security-westus"
        NSGName = "nsg-westus-default"
    }
    "North Europe" = @{
        ResourceGroupName = "rg-security-northeurope"
        NSGName = "nsg-northeurope-default"
    }
    "Southeast Asia" = @{
        ResourceGroupName = "rg-security-southeastasia"
        NSGName = "nsg-southeastasia-default"
    }
}

Write-Host "Configured NSGs for regions:" -ForegroundColor Yellow
foreach ($region in $RegionalNSGs.Keys) {
    Write-Host "  $region -> $($RegionalNSGs[$region].NSGName)" -ForegroundColor White
}
#endregion

#region Helper Functions
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

function Test-AzureConnection {
    try {
        $context = Get-AzContext
        if (-not $context) {
            Write-ColorOutput "Not connected to Azure. Please run Connect-AzAccount first." "Red"
            return $false
        }
        Write-ColorOutput "Connected to Azure as: $($context.Account.Id)" "Green"
        return $true
    }
    catch {
        Write-ColorOutput "Error checking Azure connection: $($_.Exception.Message)" "Red"
        return $false
    }
}

function Set-AzureSubscription {
    param([string]$SubscriptionId)
    
    try {
        $subscription = Get-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction SilentlyContinue
        if (-not $subscription) {
            Write-ColorOutput "Subscription $SubscriptionId not found or not accessible." "Red"
            return $false
        }
        
        Set-AzContext -SubscriptionId $SubscriptionId | Out-Null
        Write-ColorOutput "Subscription context set to: $($subscription.Name)" "Green"
        return $true
    }
    catch {
        Write-ColorOutput "Error setting subscription context: $($_.Exception.Message)" "Red"
        return $false
    }
}

function Get-RegionalNSG {
    param(
        [string]$Region,
        [hashtable]$RegionalNSGs
    )
    
    if ($RegionalNSGs.ContainsKey($Region)) {
        try {
            $nsgConfig = $RegionalNSGs[$Region]
            $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $nsgConfig.ResourceGroupName -Name $nsgConfig.NSGName -ErrorAction Stop
            return $nsg
        }
        catch {
            Write-ColorOutput "  ✗ Failed to get NSG '$($nsgConfig.NSGName)' in region '$Region': $($_.Exception.Message)" "Red"
            return $null
        }
    }
    else {
        Write-ColorOutput "  ✗ No NSG configured for region '$Region'" "Red"
        return $null
    }
}

function Test-SubnetExclusion {
    param(
        [string]$SubnetName,
        [string[]]$ExcludeList
    )
    
    return $SubnetName -in $ExcludeList
}

function Set-SubnetNSGAssociation {
    param(
        [object]$VNet,
        [object]$Subnet,
        [object]$NSG,
        [bool]$WhatIfMode = $false
    )
    
    try {
        if ($WhatIfMode) {
            Write-ColorOutput "    → WHATIF: Would associate subnet '$($Subnet.Name)' with NSG '$($NSG.Name)'" "DarkCyan"
            return @{ Success = $true; Changed = $true; Message = "Would be associated (WhatIf mode)" }
        }
        
        # Associate the subnet with the NSG
        Set-AzVirtualNetworkSubnetConfig -VirtualNetwork $VNet -Name $Subnet.Name -AddressPrefix $Subnet.AddressPrefix -NetworkSecurityGroup $NSG | Out-Null
        $result = Set-AzVirtualNetwork -VirtualNetwork $VNet
        
        if ($result) {
            Write-ColorOutput "    ✓ Successfully associated subnet '$($Subnet.Name)' with NSG '$($NSG.Name)'" "Green"
            return @{ Success = $true; Changed = $true; Message = "Successfully associated" }
        }
        else {
            Write-ColorOutput "    ✗ Failed to associate subnet '$($Subnet.Name)' with NSG '$($NSG.Name)'" "Red"
            return @{ Success = $false; Changed = $false; Message = "Association failed" }
        }
    }
    catch {
        Write-ColorOutput "    ✗ Error associating subnet '$($Subnet.Name)' with NSG: $($_.Exception.Message)" "Red"
        return @{ Success = $false; Changed = $false; Message = "Error: $($_.Exception.Message)" }
    }
}
#endregion

#region Main Processing Logic
function Invoke-RegionalNSGAssociation {
    param(
        [hashtable]$RegionalNSGs,
        [string[]]$ExcludeSubnets,
        [bool]$WhatIfMode,
        [bool]$ForceMode
    )
    
    # Initialize counters
    $statistics = @{
        TotalVNets = 0
        TotalSubnets = 0
        ProcessedSubnets = 0
        SkippedSubnets = 0
        ExcludedSubnets = 0
        SuccessfulAssociations = 0
        FailedAssociations = 0
        AlreadyAssociated = 0
        RegionStats = @{}
    }
    
    # Get all virtual networks in the subscription
    Write-ColorOutput "`nDiscovering virtual networks in subscription..." "Yellow"
    $allVNets = Get-AzVirtualNetwork
    $statistics.TotalVNets = $allVNets.Count
    
    if ($allVNets.Count -eq 0) {
        Write-ColorOutput "No virtual networks found in the subscription." "Yellow"
        return $statistics
    }
    
    Write-ColorOutput "Found $($allVNets.Count) virtual networks" "Green"
    
    # Group VNets by region for processing
    $vnetsByRegion = $allVNets | Group-Object Location
    
    foreach ($regionGroup in $vnetsByRegion) {
        $region = $regionGroup.Name
        $vnetsInRegion = $regionGroup.Group
        
        Write-ColorOutput "`n=== Processing Region: $region ===" "Cyan"
        Write-ColorOutput "VNets in region: $($vnetsInRegion.Count)" "White"
        
        # Initialize region statistics
        if (-not $statistics.RegionStats.ContainsKey($region)) {
            $statistics.RegionStats[$region] = @{
                VNets = 0
                Subnets = 0
                Processed = 0
                Skipped = 0
                Success = 0
                Failed = 0
            }
        }
        
        $regionStats = $statistics.RegionStats[$region]
        $regionStats.VNets = $vnetsInRegion.Count
        
        # Get NSG for this region
        $regionalNSG = Get-RegionalNSG -Region $region -RegionalNSGs $RegionalNSGs
        
        if (-not $regionalNSG) {
            Write-ColorOutput "  Skipping region '$region' - no NSG configured or available" "Yellow"
            continue
        }
        
        Write-ColorOutput "  Using NSG: $($regionalNSG.Name)" "Green"
        
        # Process each VNet in the region
        foreach ($vnet in $vnetsInRegion) {
            Write-ColorOutput "`n--- Processing VNet: $($vnet.Name) (RG: $($vnet.ResourceGroupName)) ---" "Yellow"
            
            if ($vnet.Subnets.Count -eq 0) {
                Write-ColorOutput "  No subnets found in VNet '$($vnet.Name)'" "Gray"
                continue
            }
            
            $regionStats.Subnets += $vnet.Subnets.Count
            $statistics.TotalSubnets += $vnet.Subnets.Count
            
            # Process each subnet in the VNet
            foreach ($subnet in $vnet.Subnets) {
                Write-ColorOutput "  Processing subnet: $($subnet.Name) ($($subnet.AddressPrefix))" "White"
                
                # Check if subnet should be excluded
                if (Test-SubnetExclusion -SubnetName $subnet.Name -ExcludeList $ExcludeSubnets) {
                    Write-ColorOutput "    ○ Excluded subnet (system/reserved subnet)" "DarkYellow"
                    $statistics.ExcludedSubnets++
                    continue
                }
                
                # Check if subnet already has an NSG associated
                if ($subnet.NetworkSecurityGroup) {
                    $currentNSGId = $subnet.NetworkSecurityGroup.Id
                    $currentNSGName = ($currentNSGId -split '/')[-1]
                    
                    if ($currentNSGId -eq $regionalNSG.Id) {
                        Write-ColorOutput "    ○ Subnet already associated with target NSG '$currentNSGName'" "DarkYellow"
                        $statistics.AlreadyAssociated++
                        $regionStats.Skipped++
                        continue
                    } else {
                        Write-ColorOutput "    ! Subnet currently has NSG '$currentNSGName', will be replaced" "Magenta"
                    }
                }
                
                # Confirm action if not in Force mode and not WhatIf
                if (-not $ForceMode -and -not $WhatIfMode) {
                    $confirmation = Read-Host "    Associate subnet '$($subnet.Name)' with NSG '$($regionalNSG.Name)'? (y/N/a for all)"
                    if ($confirmation -match '^[aA]') {
                        $ForceMode = $true
                    } elseif ($confirmation -notmatch '^[yY]') {
                        Write-ColorOutput "    ○ Skipped by user" "Yellow"
                        $statistics.SkippedSubnets++
                        $regionStats.Skipped++
                        continue
                    }
                }
                
                # Perform the association
                $result = Set-SubnetNSGAssociation -VNet $vnet -Subnet $subnet -NSG $regionalNSG -WhatIfMode $WhatIfMode
                
                $statistics.ProcessedSubnets++
                $regionStats.Processed++
                
                if ($result.Success) {
                    if ($result.Changed) {
                        $statistics.SuccessfulAssociations++
                        $regionStats.Success++
                    }
                } else {
                    $statistics.FailedAssociations++
                    $regionStats.Failed++
                }
            }
        }
    }
    
    return $statistics
}
#endregion

#region Main Script Execution
try {
    # Validate Azure connection
    if (-not (Test-AzureConnection)) {
        exit 1
    }
    
    # Set subscription context
    if (-not (Set-AzureSubscription -SubscriptionId $SubscriptionId)) {
        exit 1
    }
    
    # Display configuration
    Write-ColorOutput "`nConfiguration:" "Cyan"
    Write-ColorOutput "Subscription ID: $SubscriptionId" "White"
    Write-ColorOutput "Excluded subnets: $($ExcludeSubnets -join ', ')" "White"
    Write-ColorOutput "WhatIf mode: $WhatIf" "White"
    Write-ColorOutput "Force mode: $Force" "White"
    
    # Validate NSGs exist
    Write-ColorOutput "`nValidating NSGs..." "Yellow"
    $nsgValidationFailed = $false
    
    foreach ($region in $RegionalNSGs.Keys) {
        $nsgConfig = $RegionalNSGs[$region]
        try {
            $nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $nsgConfig.ResourceGroupName -Name $nsgConfig.NSGName -ErrorAction Stop
            Write-ColorOutput "✓ NSG '$($nsgConfig.NSGName)' found in region '$region'" "Green"
        }
        catch {
            Write-ColorOutput "✗ NSG '$($nsgConfig.NSGName)' not found in region '$region': $($_.Exception.Message)" "Red"
            $nsgValidationFailed = $true
        }
    }
    
    if ($nsgValidationFailed) {
        Write-ColorOutput "`nNSG validation failed. Please check NSG names and resource groups." "Red"
        exit 1
    }
    
    # Process associations
    $statistics = Invoke-RegionalNSGAssociation -RegionalNSGs $RegionalNSGs -ExcludeSubnets $ExcludeSubnets -WhatIfMode $WhatIf -ForceMode $Force
    
    # Display summary
    Write-ColorOutput "`n=== SUMMARY ===" "Cyan"
    Write-ColorOutput "Total VNets processed: $($statistics.TotalVNets)" "White"
    Write-ColorOutput "Total subnets found: $($statistics.TotalSubnets)" "White"
    Write-ColorOutput "Subnets processed: $($statistics.ProcessedSubnets)" "White"
    Write-ColorOutput "Successful associations: $($statistics.SuccessfulAssociations)" "Green"
    Write-ColorOutput "Failed associations: $($statistics.FailedAssociations)" "Red"
    Write-ColorOutput "Already associated: $($statistics.AlreadyAssociated)" "Yellow"
    Write-ColorOutput "Excluded subnets: $($statistics.ExcludedSubnets)" "Gray"
    Write-ColorOutput "Skipped subnets: $($statistics.SkippedSubnets)" "Yellow"
    
    # Regional breakdown
    Write-ColorOutput "`n=== REGIONAL BREAKDOWN ===" "Cyan"
    foreach ($region in $statistics.RegionStats.Keys) {
        $regionStats = $statistics.RegionStats[$region]
        Write-ColorOutput "$region:" "Yellow"
        Write-ColorOutput "  VNets: $($regionStats.VNets) | Subnets: $($regionStats.Subnets)" "White"
        Write-ColorOutput "  Processed: $($regionStats.Processed) | Success: $($regionStats.Success) | Failed: $($regionStats.Failed) | Skipped: $($regionStats.Skipped)" "White"
    }
    
    Write-ColorOutput "`nScript completed at: $(Get-Date)" "Green"
    
    if ($WhatIf) {
        Write-ColorOutput "`nThis was a WHATIF run. No actual changes were made." "DarkCyan"
        Write-ColorOutput "Remove the -WhatIf parameter to apply the changes." "DarkCyan"
    }
    
    # Export results to CSV
    if ($statistics.ProcessedSubnets -gt 0) {
        $resultsFile = "nsg-association-results-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
        
        $results = @()
        foreach ($region in $statistics.RegionStats.Keys) {
            $regionStats = $statistics.RegionStats[$region]
            $results += [PSCustomObject]@{
                Region = $region
                VNets = $regionStats.VNets
                TotalSubnets = $regionStats.Subnets
                ProcessedSubnets = $regionStats.Processed
                SuccessfulAssociations = $regionStats.Success
                FailedAssociations = $regionStats.Failed
                SkippedSubnets = $regionStats.Skipped
                NSGUsed = if ($RegionalNSGs.ContainsKey($region)) { $RegionalNSGs[$region].NSGName } else { "None" }
                Timestamp = Get-Date
            }
        }
        
        $results | Export-Csv -Path $resultsFile -NoTypeInformation
        Write-ColorOutput "Results exported to: $resultsFile" "Gray"
    }
}
catch {
    Write-ColorOutput "Script execution failed: $($_.Exception.Message)" "Red"
    Write-ColorOutput "Full error: $($_.Exception)" "DarkRed"
    exit 1
}
#endregion