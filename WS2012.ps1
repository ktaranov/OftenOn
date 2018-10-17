Configuration WS2012 {
    param (
    )

    #region Resources
    Import-DscResource -ModuleName PSDesiredStateConfiguration
    Import-DscResource -ModuleName ComputerManagementDsc
    Import-DscResource -ModuleName NetworkingDsc
    Import-DscResource -ModuleName xActiveDirectory
    Import-DscResource -ModuleName xDnsServer
    Import-DscResource -ModuleName xRemoteDesktopAdmin
    Import-DscResource -ModuleName xSmbShare
    Import-DscResource -ModuleName xSystemSecurity
    Import-DscResource -ModuleName C:\Git\xFailOverCluster
    Import-DscResource -ModuleName C:\Git\SqlServerDsc
    Import-DscResource -ModuleName C:\Git\xPSDesiredStateConfiguration
    Import-DscResource -ModuleName xWinEventLog
    #endregion

    $clusterOrder = @{}
    $availabilityReplicaOrder = @{}
    $domainController = @{}

    Node $AllNodes.NodeName {
        # When building the domain the UserName is ignored. But the domain part of the username is required to use the credential to add computers to the domain.
        $domainAdministrator = New-Object System.Management.Automation.PSCredential("$($node.DomainName)\Administrator", ('Admin2018!' | ConvertTo-SecureString -AsPlainText -Force))
        $safemodeAdministrator = New-Object System.Management.Automation.PSCredential('Administrator', ('Safe2018!' | ConvertTo-SecureString -AsPlainText -Force))
        # These accounts must have the domain part stripped when they are created, because they're added by the ActiveDirectory module @lab.com
        $localAdministrator = New-Object System.Management.Automation.PSCredential("$($node.DomainName)\LocalAdministrator", ('Local2018!' | ConvertTo-SecureString -AsPlainText -Force))
        $sqlEngineService = New-Object System.Management.Automation.PSCredential("$($node.DomainName)\SQLEngineService", ('Engine2018!' | ConvertTo-SecureString -AsPlainText -Force))

        # These starting blocks don't have dependencies

        #region Local Configuration Manager settings
        LocalConfigurationManager {
            RebootNodeIfNeeded   = $true
            AllowModuleOverwrite = $true
            CertificateID        = $node.Thumbprint

            # This retries the configuration every 15 minutes (the minimum) until it has entirely passed once
            ConfigurationMode    = 'ApplyOnly'
            ConfigurationModeFrequencyMins = 15
        }
        #endregion

        #region Registry settings useful in a lab

        #region Enable DSC logging
        xWinEventLog "EnableDSCAnalyticLog" {
            LogName = "Microsoft-Windows-DSC/Analytic"
            IsEnabled = $true
        }

        xWinEventLog "EnableDSCDebugLog" {
            LogName = "Microsoft-Windows-DSC/Debug"
            IsEnabled = $true
        }
        #endregion

        # Stop Windows from caching "not found" DNS requests (defaults at 15 minutes) because it slows down DSC WaitForX
        Registry 'DisableNegativeCacheTtl' {
            Ensure = 'Present'
            Key = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters'
            ValueName = 'MaxNegativeCacheTtl'
            ValueData = '0'
            ValueType = 'DWord'
        }

        # Stop Windows from cycling machine passwors in a domain that prevent snapshots > 30 days old from booting
        Registry 'DisableMachineAccountPasswordChange' {
            Ensure = 'Present'
            Key = 'HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Netlogon\Parameters'
            ValueName = 'DisablePasswordChange'
            ValueData = '1'
            ValueType = 'DWord'
        }
        #endregion

        #region Enable Remote Desktop
        # Enable the service
        xRemoteDesktopAdmin 'EnableRemoteDesktopService' {
            Ensure             = 'Present'
            UserAuthentication = 'NonSecure'
        }

        # Enable firewall exceptions
        foreach ($firewallRule in @('FPS-ICMP4-ERQ-In', 'FPS-ICMP6-ERQ-In', 'RemoteDesktop-UserMode-In-TCP', 'RemoteDesktop-UserMode-In-UDP')) {
            # In current versions of DSC you can pass a built-in rule name and enable it without specifying all of the other details
            Firewall "Enable$($firewallRule.Replace('-', ''))" {
                Name    = $firewallRule
                Ensure  = 'Present'
                Enabled = 'True'
            }
        }

        # Bulk-enable firewall exceptions for File and Printer sharing (needed to RDP from your host)
        Script 'EnableFileAndPrinterSharing' {
            GetScript = {
                if (Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing' | Where-Object { $_.Enabled -eq 'False' }) {
                    @{ Result = "false"; }
                } else {
                    @{ Result = "true"; }
                }
            }
            TestScript = {
                if (Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing' | Where-Object { $_.Enabled -eq 'False' }) {
                    $false
                } else {
                    $true
                }
            }
            SetScript = {
                Get-NetFirewallRule -DisplayGroup 'File and Printer Sharing' | Where-Object { $_.Enabled -eq 'False' } | Set-NetFirewallRule -Enabled True
            }
        }
        #endregion

        #region Add a C:\Temp
        File 'CreateTempDirectory' {
            DestinationPath = 'C:\Temp'
            Ensure = 'Present'
            Type = 'Directory'
        }

        xFileSystemAccessRule 'GrantAccessToLocalTempFolder' {
            Path = 'C:\Temp'
            Identity = 'EVERYONE'
            Rights = @('FullControl')
            DependsOn = '[File]CreateTempDirectory'
        }
        #endregion

        #region Add basic Windows features depending on Role
        $windowsFeatures = 'RSAT-AD-Tools', 'RSAT-AD-PowerShell', 'RSAT-Clustering', 'RSAT-Clustering-CmdInterface', 'RSAT-DNS-Server', 'RSAT-RemoteAccess'
        if ($node.ContainsKey('Role')) {
            if ($node.Role.ContainsKey('DomainController')) {
                $windowsFeatures += 'AD-Domain-Services', 'DNS'
            }
            if ($node.Role.ContainsKey('Cluster')) {
                $windowsFeatures += 'Failover-Clustering'
            }
            if ($node.Role.ContainsKey('Router')) {
                $windowsFeatures += 'Routing'
            }
        }
        WindowsFeatureSet "All" {
            Name   = $windowsFeatures
            Ensure = 'Present'
        }
        #endregion
        #       ^-- DependsOn 'WindowsFeatureSet[All]'

        # More complex dependency chains start here

        #region Rename network adapters and configure settings
        if ($node.ContainsKey('Network')) {
            for ($i = 0; $i -lt $node.Network.Count; $i++) {
                $network = $node.Network[$i]

                NetAdapterName "Rename$($network.NetAdapterName)" {
                    NewName = $network.NetAdapterName
                    MacAddress = $node.Lability_MACAddress[$i].Replace(':', '-')
                }

                if ($network.ContainsKey('IPAddress')) {
                    IPAddress "SetIPAddress$($network.NetAdapterName)" {
                        AddressFamily = 'IPv4'
                        InterfaceAlias = $network.NetAdapterName
                        IPAddress = $network.IPAddress
                        DependsOn = "[NetAdapterName]Rename$($network.NetAdapterName)"
                    }
                }

                if ($network.ContainsKey('DefaultGatewayAddress')) {
                    DefaultGatewayAddress "SetDefaultGatewayAddress$($network.NetAdapterName)" {
                        AddressFamily = 'IPv4'
                        InterfaceAlias = $network.NetAdapterName
                        Address = $network.DefaultGatewayAddress
                        DependsOn = "[NetAdapterName]Rename$($network.NetAdapterName)"
                    }
                }

                if ($network.ContainsKey('DnsServerAddress')) {
                    DnsServerAddress "SetDnsServerAddress$($network.NetAdapterName)" {
                        AddressFamily  = 'IPv4'
                        InterfaceAlias = $network.NetAdapterName
                        Address        = $network.DnsServerAddress
                        DependsOn = "[NetAdapterName]Rename$($network.NetAdapterName)"
                    }
                }

                DnsConnectionSuffix "SetDnsConnectionSuffix$($network.NetAdapterName)" {
                    InterfaceAlias           = $network.NetAdapterName
                    ConnectionSpecificSuffix = $node.FullyQualifiedDomainName
                    DependsOn = "[NetAdapterName]Rename$($network.NetAdapterName)"
                }
            }
        }
        #endregion
        #       ^-- DependsOn "[NetAdapterName]Rename$($network.NetAdapterName)"

        if ($node.ContainsKey('Role')) {
            if ($node.Role.ContainsKey('Router')) {
                #region Enable subnet routing on the Domain Controller
                Script 'EnableRouting' {
                    GetScript = {
                        if (Get-NetIPInterface | Where-Object { $_.Forwarding -ne 'Enabled' }) {
                            @{ Result = "false"; }
                        } else {
                            @{ Result = "true"; }
                        }
                    }
                    TestScript = {
                        if (Get-NetIPInterface | Where-Object { $_.Forwarding -ne 'Enabled' }) {
                            $false
                        } else {
                            $true
                        }
                    }
                    SetScript = {
                        Get-NetIPInterface | Where-Object { $_.Forwarding -ne 'Enabled' } | Set-NetIPInterface -Forwarding Enabled
                    }

                    # DependsOn      = '[Computer]Rename'
                }
                #endregion
            }
        }

        #region Active Directory
        if ($node.ContainsKey('Role')) {
            if ($node.Role.ContainsKey('DomainController')) {
                $domainController.$($node.DomainName) = $node.NodeName

                # These execute in sequence

                #region Rename the computer
                Computer 'Rename' {
                    Name = $node.NodeName
                }
                #endregion

                #region Create Domain
                xADDomain 'Create' {
                    DomainName                    = $node.FullyQualifiedDomainName
                    DomainAdministratorCredential = $domainAdministrator
                    SafemodeAdministratorPassword = $safemodeAdministrator

                    DependsOn                     = '[WindowsFeatureSet]All'
                }
                #endregion

                #region Disable DNS forwarding, this stops other machines from resolving internet addresses
                xDnsServerSetting 'DisableDnsForwarding' {
                    Name = 'DNS'
                    NoRecursion = $true
                    DependsOn = '[xADDomain]Create'
                }
                #endregion

                #region Create Users/Groups
                xADUser 'CreateUserSQLEngineService' {
                    # Make sure the UserName is a straight username because the DSC adds @DomainName onto the end.
                    DomainName  = $node.FullyQualifiedDomainName
                    UserName    = ($sqlEngineService.UserName -split '\\')[1]
                    Description = 'SQL Engine Service'
                    Password    = $sqlEngineService
                    Ensure      = 'Present'
                    DependsOn   = '[xADDomain]Create'
                }

                xADUser "CreateLocalAdministrator" {
                    DomainName  = $node.FullyQualifiedDomainName
                    UserName    = ($localAdministrator.UserName -split '\\')[1]
                    Description = 'Local Administrator'
                    Password    = $localAdministrator
                    Ensure      = 'Present'
                    DependsOn   = '[xADDomain]Create'
                }
                #endregion

                #region Create a Resources and Temp share on the Domain Controller for other VMs to use
                xSmbShare 'CreateResources' {
                    Name = 'Resources'
                    Ensure = 'Present'

                    Path = 'C:\Resources'
                    ReadAccess = 'Everyone'

                    DependsOn = '[xADDomain]Create'
                }

                xSmbShare 'CreateTemp' {
                    Name = 'Temp'
                    Ensure = 'Present'

                    Path = 'C:\Temp'
                    FullAccess = 'Everyone'

                    DependsOn = '[xADDomain]Create'
                }
                #endregion
            } elseif ($node.Role.ContainsKey('DomainMember')) {
                #region Wait for Active Directory
                # If you don't have a WAN link, the fully qualified domain name works here
                # and in the computer rename. If you do have a WAN link and disable forwarding
                # then you MUST use the short domain name otherwise the domain isn't found.
                # However it will then break. So not being able to use a full one indicates
                # another issue in your setpu.
                xWaitForADDomain 'Create' {
                    DomainName           = $node.FullyQualifiedDomainName
                    DomainUserCredential = $domainAdministrator
                    # 30 Minutes
                    RetryIntervalSec     = 15
                    RetryCount           = 120
                }
                #endregion

                #region Rename computer (while joining to Active Directory)
                Computer 'Rename' {
                    Name       = $node.NodeName
                    DomainName = $node.FullyQualifiedDomainName
                    Credential = $domainAdministrator
                    DependsOn  = '[xWaitForADDomain]Create'
                }
                #endregion

                #region Add LocalAdministrator to Administrators Group
                WaitForAll "CreateLocalAdministrator" {
                    ResourceName = '[xADUser]CreateLocalAdministrator'
                    NodeName = $domainController.$($node.DomainName)

                    # 30 Minutes
                    RetryIntervalSec = 15
                    RetryCount       = 120
                }

                Group 'AddLocalAdministratorToAdministratorsGroup' {
                    GroupName = 'Administrators'
                    Ensure = 'Present'
                    MembersToInclude = $localAdministrator.UserName
                    DependsOn = '[WaitForAll]CreateLocalAdministrator'
                }
                #endregion
            }
        }
        #endregion

        #region Clustering
        if ($node.ContainsKey("Role")) {
            if ($node.Role.ContainsKey('Cluster')) {
                $cluster = $node.Role.Cluster
                $clusterStaticAddress = $cluster.StaticAddress
                $clusterIgnoreNetwork = $cluster.IgnoreNetwork

                if (!$clusterOrder.ContainsKey($cluster.Name)) {
                    $clusterOrder.$($cluster.Name) = [array] $node.NodeName
                    xCluster "AddNodeToCluster$($cluster.Name)" {
                        Name                          = $cluster.Name
                        DomainAdministratorCredential = $domainAdministrator
                        StaticIPAddress               = $clusterStaticAddress.CIDR
                        IgnoreNetwork                 = $clusterIgnoreNetwork.CIDR
                        # If RSAT-Clustering is not installed the cluster can not be created
                        DependsOn                     = '[WindowsFeatureSet]All', '[Computer]Rename'
                    }
                } else {
                    WaitForAll "WaitForCluster$($cluster.Name)" {
                        ResourceName = "[xCluster]AddNodeToCluster$($cluster.Name)"
                        NodeName = ($clusterOrder.$($cluster.Name))[-1]

                        # 30 Minutes
                        RetryIntervalSec = 15
                        RetryCount       = 120

                        # If RSAT-Clustering is not installed the cluster can not be created
                        DependsOn        = '[WindowsFeatureSet]All', '[Computer]Rename'
                    }

                    xCluster "AddNodeToCluster$($cluster.Name)" {
                        Name                          = $cluster.Name
                        DomainAdministratorCredential = $domainAdministrator
                        StaticIPAddress               = $clusterStaticAddress.CIDR
                        IgnoreNetwork                 = $clusterIgnoreNetwork.CIDR
                        DependsOn                     = "[WaitForAll]WaitForCluster$($cluster.Name)"
                    }

                    $clusterOrder.$($cluster.Name) += [array] $node.NodeName

                    Script "AddStaticIPToCluster$($cluster.Name)" {
                        GetScript = {
                            if (Get-ClusterResource | Where-Object { $_.ResourceType -eq 'IP Address' } | Get-ClusterParameter -Name Address | Where-Object { $_.Value -eq $using:clusterStaticAddress.IPAddress }) {
                                @{ Result = "true"; }
                            } else {
                                @{ Result = "false"; }
                            }
                        }
                        TestScript = {
                            if (Get-ClusterResource | Where-Object { $_.ResourceType -eq 'IP Address' } | Get-ClusterParameter -Name Address | Where-Object { $_.Value -eq $using:clusterStaticAddress.IPAddress }) {
                                $true
                            } else {
                                $false
                            }
                        }
                        SetScript = {
                            $resourceName = "IP Address $($using:clusterStaticAddress.IPAddress)"
                            Get-Cluster | Add-ClusterResource -Name $resourceName -Group 'Cluster Group' -ResourceType 'IP Address'
                            Get-ClusterResource -Name $resourceName | Set-ClusterParameter -Multiple @{ Address = $clusterStaticAddress.IPAddress; Network = $using:clusterStaticAddress.Name; SubnetMask = $using:clusterStaticAddress.SubnetMask; }
                            $dependencyExpression = (Get-Cluster | Get-ClusterResourceDependency -Resource 'Cluster Name').DependencyExpression
                            if ($dependencyExpression -match '^\((.*)\)$') {
                                $dependencyExpression = $Matches[1] + " or [$resourceName]"
                            } else {
                                $dependencyExpression = $dependencyExpression + " or [$resourceName]"
                            }
                            Get-Cluster | Set-ClusterResourceDependency -Resource 'Cluster Name' -Dependency $dependencyExpression
                            # Without this, it won't start automatically on first try
                            (Get-Cluster | Get-ClusterResource -Name $resourceName).PersistentState = 1
                        }

                        DependsOn = "[xClusterNetwork]RenameClusterNetwork$($cluster.Name)Client", "[xClusterNetwork]RenameClusterNetwork$($cluster.Name)Heartbeat"
                    }
                }

                xClusterNetwork "RenameClusterNetwork$($cluster.Name)Client" {
                    Address = $clusterStaticAddress.NetworkID
                    AddressMask = $clusterStaticAddress.SubnetMask
                    Name = $clusterStaticAddress.Name
                    Role = 3 # Heartbeat and Client

                    DependsOn = "[xCluster]AddNodeToCluster$($cluster.Name)"
                }

                xClusterNetwork "RenameClusterNetwork$($cluster.Name)Heartbeat" {
                    Address = $clusterIgnoreNetwork.NetworkID
                    AddressMask = $clusterIgnoreNetwork.SubnetMask
                    Name = $clusterIgnoreNetwork.Name
                    Role = 1 # Heartbeat Only

                    DependsOn = "[xCluster]AddNodeToCluster$($cluster.Name)"
                }
            }
        }
        #endregion

        #region SQL Server
        if ($node.ContainsKey('Role')) {
            if ($node.Role.ContainsKey('SqlServer')) {
                SqlSetup 'InstallSQLServer' {
                    InstanceName = $node.Role.SqlServer.InstanceName
                    Action = 'Install'
                    SourcePath = $node.Role.SqlServer.SourcePath
                    Features = $node.Role.SqlServer.Features
                    SQLSvcAccount = $sqlEngineService
                    SQLSysAdminAccounts = $localAdministrator.UserName
                    UpdateEnabled = 'False'

                    DependsOn = "[xCluster]AddNodeToCluster$($cluster.Name)"
                }

                SqlWindowsFirewall 'AddFirewallRuleSQL' {
                    InstanceName = $node.Role.SqlServer.InstanceName
                    SourcePath = $node.Role.SqlServer.SourcePath
                    Features = $node.Role.SqlServer.Features
                    Ensure = 'Present'

                    DependsOn = '[SqlSetup]InstallSQLServer'
                }

                SqlAlwaysOnService 'EnableAlwaysOn' {
                    ServerName = $node.NodeName
                    InstanceName = $node.Role.SqlServer.InstanceName
                    Ensure = 'Present'

                    DependsOn = '[SqlWindowsFirewall]AddFirewallRuleSQL'
                }

                SqlServerLogin 'CreateLoginForAG'
                {
                    Ensure               = 'Present'
                    ServerName           = $node.NodeName
                    InstanceName         = $node.Role.SqlServer.InstanceName
                    Name                 = $sqlEngineService.UserName

                    DependsOn = '[SqlSetup]InstallSQLServer'
                    PsDscRunAsCredential = $localAdministrator
                }

                SqlServerEndpoint 'CreateHadrEndpoint'
                {
                    EndPointName         = 'Hadr_endpoint' # For some reason the Examples use HADR; but this is what the wizard uses
                    Ensure               = 'Present'
                    Port                 = 5022
                    ServerName           = $node.NodeName
                    InstanceName         = $node.Role.SqlServer.InstanceName

                    DependsOn = '[SqlAlwaysOnService]EnableAlwaysOn'
                }

                SqlServerEndpointPermission 'AddLoginForAGEndpointPermission'
                {
                    Ensure               = 'Present'
                    ServerName           = $node.NodeName
                    InstanceName         = $node.Role.SqlServer.InstanceName
                    Name                 = 'Hadr_endpoint'
                    Principal            = $sqlEngineService.UserName
                    Permission           = 'CONNECT'

                    PsDscRunAsCredential = $localAdministrator
                    DependsOn = '[SqlServerEndpoint]CreateHadrEndpoint', '[SqlServerLogin]CreateLoginForAG'
                }


                SqlServerPermission 'AddPermissionsForAGMembership'
                {
                    Ensure               = 'Present'
                    ServerName           = $node.NodeName
                    InstanceName         = $node.Role.SqlServer.InstanceName
                    Principal            = 'NT AUTHORITY\SYSTEM'
                    Permission           = 'AlterAnyAvailabilityGroup', 'ViewServerState'

                    DependsOn = '[SqlSetup]InstallSQLServer'
                    PsDscRunAsCredential = $localAdministrator
                }

                if ($node.Role.ContainsKey("AvailabilityGroup")) {
                    if (!$availabilityReplicaOrder.ContainsKey($node.Role.AvailabilityGroup.Name)) {
                        $availabilityReplicaOrder.$($node.Role.AvailabilityGroup.Name) = [array] $node.NodeName

                        # Create the availability group on the instance tagged as the primary replica
                        SqlAG "CreateAvailabilityGroup$($node.Role.AvailabilityGroup.Name)" {
                            Ensure               = 'Present'
                            Name                 = $node.Role.AvailabilityGroup.Name
                            InstanceName         = $node.Role.SQLServer.InstanceName
                            ServerName           = $node.NodeName
                            DependsOn            = '[SqlServerPermission]AddPermissionsForAGMembership'
                            PsDscRunAsCredential = $localAdministrator
                        }

                        $completeListenerList = $AllNodes | Where-Object { $_.ContainsKey('Role') -and $_.Role.ContainsKey('AvailabilityGroup') -and $_.Role.AvailabilityGroup.Name -eq $node.Role.AvailabilityGroup.Name } | ForEach-Object { $_.Role.AvailabilityGroup.IPAddress } | Select-Object -Unique

                        <#
                            If you try to create a listener with an IP but not the IP on the primary, it will fail.

                            None of the IP addresses configured for the availability group listener can be hosted by the server 'SEC1N1'. Either
                            configure a public cluster network on which one of the specified IP addresses can be hosted, or add another listener
                            IP address which can be hosted on a public cluster network for this server.
                                + CategoryInfo          : InvalidOperation: (:) [], CimException
                                + FullyQualifiedErrorId : ExecutionFailed,Microsoft.SqlServer.Management.PowerShell.Hadr.NewSqlAvailabilityGroupLi
                            stenerCommand
                                + PSComputerName        : DAC1N1

                            If you have a listener with an IP:
                                If you try to add another server you need to add it on one side, add the listener
                                IP, and then join on the secondary, otherwise you'll get an error trying to join the secondary too early because
                                there's no listener IP. DSC isn't this fine-grained.
                            If you have a listener defined with all IPs:
                                You can join immediately.
                            If you have no listener, you can join easily.
                        #>
                        SqlAGListener "CreateListener$($node.Role.AvailabilityGroup.ListenerName)" {
                            Ensure               = 'Present'
                            ServerName           = $node.NodeName
                            InstanceName         = $node.Role.SQLServer.InstanceName
                            AvailabilityGroup    = $node.Role.AvailabilityGroup.Name
                            Name                 = $node.Role.AvailabilityGroup.ListenerName
                            IpAddress            = $completeListenerList
                            Port                 = 1433

                            PsDscRunAsCredential = $localAdministrator
                            DependsOn = "[SqlAg]CreateAvailabilityGroup$($node.Role.AvailabilityGroup.Name)"
                        }

                        SqlDatabase "CreateDatabaseDummy$($node.Role.AvailabilityGroup.Name)" {
                            Ensure       = 'Present'
                            ServerName   = $node.NodeName
                            InstanceName = $node.Role.SQLServer.InstanceName
                            Name         = "Dummy$($node.Role.AvailabilityGroup.Name)"
                            PsDscRunAsCredential = $localAdministrator
                            DependsOn = '[SqlSetup]InstallSQLServer'
                        }

                        SqlDatabaseRecoveryModel "SetDatabaseRecoveryModelDummy$($node.Role.AvailabilityGroup.Name)" {
                            Name         = "Dummy$($node.Role.AvailabilityGroup.Name)"
                            RecoveryModel        = 'Full'
                            ServerName           = $node.NodeName
                            InstanceName         = $node.Role.SQLServer.InstanceName
                            PsDscRunAsCredential = $localAdministrator
                            DependsOn = "[SqlDatabase]CreateDatabaseDummy$($node.Role.AvailabilityGroup.Name)"
                        }

                        $completeReplicaList = $AllNodes | Where-Object { $_.NodeName -ne $node.NodeName -and $_.ContainsKey('Role') -and $_.Role.ContainsKey('AvailabilityGroup') -and $_.Role.AvailabilityGroup.Name -eq $node.Role.AvailabilityGroup.Name } | ForEach-Object { $_.NodeName }

                        # This won't give you an error if you forget the resource [] part of the ResourceName!
                        WaitForAll 'WaitForAllAGReplicas' {
                            ResourceName = "[SqlAGReplica]AddReplicaToAvailabilityGroup$($node.Role.AvailabilityGroup.Name)"
                            NodeName = $completeReplicaList
                            RetryCount = 120
                            RetryIntervalSec = 15
                            DependsOn = "[SqlDatabaseRecoveryModel]SetDatabaseRecoveryModelDummy$($node.Role.AvailabilityGroup.Name)"
                        }

                        # This really needs wait for all replicas to be added
                        # This will give an error if you use MatchDatabaseOwner on SQL 2012
                        SqlAGDatabase "AddDatabaseTo$($node.Role.AvailabilityGroup.Name)" {
                            AvailabilityGroupName   = $node.Role.AvailabilityGroup.Name
                            BackupPath              = '\\CHDC01\Temp' # TODO: Remove this
                            DatabaseName            = "Dummy$($node.Role.AvailabilityGroup.Name)"
                            ServerName              = $node.NodeName
                            InstanceName            = $node.Role.SQLServer.InstanceName
                            Ensure                  = 'Present'
                            PsDscRunAsCredential    = $localAdministrator
                            # MatchDatabaseOwner = $true # EXECUTE AS
                            DependsOn = '[WaitForAll]WaitForAllAGReplicas'
                        }
                    } else {
                        WaitForAll "WaitFor$($node.Role.AvailabilityGroup.ListenerName)" {
                            ResourceName         = "[SqlAGListener]CreateListener$($node.Role.AvailabilityGroup.ListenerName)"
                            NodeName             = $availabilityReplicaOrder.$($node.Role.AvailabilityGroup.Name)[0]
                            RetryIntervalSec     = 15
                            RetryCount           = 120

                            PsDscRunAsCredential = $localAdministrator
                        }

                        SqlAGReplica "AddReplicaToAvailabilityGroup$($node.Role.AvailabilityGroup.Name)" {
                            Ensure               = 'Present'
                            AvailabilityGroupName = $node.Role.AvailabilityGroup.Name

                            Name                 = $node.NodeName # X\X format
                            ServerName           = $node.NodeName
                            InstanceName         = $node.Role.SQLServer.InstanceName
                            PrimaryReplicaServerName   = $availabilityReplicaOrder.$($node.Role.AvailabilityGroup.Name)[0]
                            PrimaryReplicaInstanceName = $node.Role.SQLServer.InstanceName
                            DependsOn            = "[WaitForAll]WaitFor$($node.Role.AvailabilityGroup.ListenerName)"
                            PsDscRunAsCredential = $localAdministrator
                        }
                    }

                }
            }
        }
        #endregion

        #region Workstation
        if ($node.ContainsKey('Role')) {
            if ($node.Role.ContainsKey('Workstation')) {
                $resourceLocation = "\\$($domainController.$($node.DomainName))\Resources"

                Script 'NetFx472' {
                    GetScript = {
                        Set-StrictMode -Version Latest; $ErrorActionPreference = "Stop";

                        $release = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' 'Release' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Release
                        @{ Result = "$release"; }
                    }
                    TestScript = {
                        Set-StrictMode -Version Latest; $ErrorActionPreference = "Stop";

                        $release = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' 'Release' -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Release
                        if ($release -and $release -ge 461814) {
                            $true
                        } else {
                            $false
                        }
                    }
                    SetScript = {
                        Set-StrictMode -Version Latest; $ErrorActionPreference = "Stop";

                        # If you don't use -NoNewWindow it will hang with an Open File - Security Warning
                        $result = Start-Process -FilePath "$using:resourceLocation\NDP472-KB4054530-x86-x64-AllOS-ENU.exe" -ArgumentList '/quiet' -PassThru -Wait -NoNewWindow
                        if ($result.ExitCode -in @(1641, 3010)) {
                            $global:DSCMachineStatus = 1
                        } elseif ($result.ExitCode -ne 0) {
                            Write-Error "Installation failed with exit code $($result.ExitCode)"
                        } else {
                            Write-Verbose "Installation succeeded"
                        }
                    }
                }

                # ProductId is critical to get right, if it's not right then the computer will keep rebooting
                <#
                Get-ChildItem -Path 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall' | 
                    Where-Object { $_.Property -contains 'DisplayName' -and $_.GetValue('DisplayName') -like "*17.9*" } | 
                    ForEach-Object { $_.GetValue('BundleProviderKey') }
                #>
                xPackage 'SSMS179' {
                    Name = 'SSMS179'
                    Path = "$resourceLocation\SSMS-Setup-ENU.exe"
                    ProductId = 'a0010c7f-d2e9-486b-a658-a1a1106847da'
                    Arguments = '/install /quiet'
                    DependsOn  = '[Script]NetFx472'
                }
            }
        }
    }
}
