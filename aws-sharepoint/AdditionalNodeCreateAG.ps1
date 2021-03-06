[CmdletBinding()]
param(

    [Parameter(Mandatory=$true)]
    [string]$DomainNetBIOSName,

    [Parameter(Mandatory=$true)]
    [string]$AdminSecret,

    [Parameter(Mandatory=$true)]
    [string]$SQLSecret,

    [Parameter(Mandatory=$true)]
    [string]$ClusterName,

    [Parameter(Mandatory=$true)]
    [string]$AvailabiltyGroupName,

    [Parameter(Mandatory=$true)]
    [string]$PrimaryNetBIOSName
)

#~dk
#Retrieve Parameters and Convert from string to Secure String
$AdminSecret_Str = (Get-SSMParameterValue -Names $AdminSecret).Parameters[0].Value
Write-SSMParameter -Name $AdminSecret -Type SecureString -Value $AdminSecret_Str -Overwrite $true
$SQLSecret_Str = (Get-SSMParameterValue -Names $SQLSecret).Parameters[0].Value
Write-SSMParameter -Name $SQLSecret -Type SecureString -Value $SQLSecret_Str -Overwrite $true

#~dk
# Getting Password from Secrets Manager for AD Admin User
$AdminUser = ConvertFrom-Json -InputObject (Get-SSMParameterValue -Names $AdminSecret -WithDecryption $True).Parameters[0].Value
$SQLUser = ConvertFrom-Json -InputObject (Get-SSMParameterValue -Names $SQLSecret -WithDecryption $True).Parameters[0].Value


# Getting the DSC Cert Encryption Thumbprint to Secure the MOF File
$DscCertThumbprint = (get-childitem -path cert:\LocalMachine\My | where { $_.subject -eq "CN=AWSQSDscEncryptCert" }).Thumbprint
# Getting Password from Secrets Manager for AD Admin User
#$AdminUser = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $AdminSecret).SecretString
#$SQLUser = ConvertFrom-Json -InputObject (Get-SECSecretValue -SecretId $SQLSecret).SecretString
$ClusterAdminUser = $DomainNetBIOSName + '\' + $AdminUser.UserName
$SQLAdminUser = $DomainNetBIOSName + '\' + $SQLUser.UserName
# Creating Credential Object for Administrator
$Credentials = (New-Object PSCredential($ClusterAdminUser,(ConvertTo-SecureString $AdminUser.Password -AsPlainText -Force)))
$SQLCredentials = (New-Object PSCredential($SQLAdminUser,(ConvertTo-SecureString $SQLUser.Password -AsPlainText -Force)))
# Getting the Name Tag of the Instance
$NameTag = (Get-EC2Tag -Filter @{ Name="resource-id";Values=(Invoke-RestMethod -Method Get -Uri http://169.254.169.254/latest/meta-data/instance-id)}| Where-Object { $_.Key -eq "Name" })
$NetBIOSName = $NameTag.Value

$ConfigurationData = @{
    AllNodes = @(
        @{
            NodeName     = '*'
            CertificateFile = "C:\AWSQuickstart\publickeys\AWSQSDscPublicKey.cer"
            Thumbprint = $DscCertThumbprint
            PSDscAllowDomainUser = $true
        },
        @{
            NodeName = $NetBIOSName
        }
    )
}

Configuration AddAG {
    param(
        [Parameter(Mandatory = $true)]
        [PSCredential]$SQLCredentials,

        [Parameter(Mandatory = $true)]
        [PSCredential]$Credentials
    )

    Import-Module -Name PSDesiredStateConfiguration
    Import-Module -Name xActiveDirectory
    Import-Module -Name SqlServerDsc
    
    Import-DscResource -Module PSDesiredStateConfiguration
    Import-DscResource -Module xActiveDirectory
    Import-DscResource -Module SqlServerDsc

    Node $AllNodes.NodeName {
        SqlServerMaxDop 'SQLServerMaxDopAuto' {
            Ensure                  = 'Present'
            DynamicAlloc            = $true
            ServerName              = $NetBIOSName
            InstanceName            = 'MSSQLSERVER'
            PsDscRunAsCredential    = $SQLCredentials
            ProcessOnlyOnActiveNode = $true
        }

        SqlServerConfiguration 'SQLConfigPriorityBoost'{
            ServerName     = $NetBIOSName
            InstanceName   = 'MSSQLSERVER'
            OptionName     = 'cost threshold for parallelism'
            OptionValue    = 20
        }

        SqlAlwaysOnService 'EnableAlwaysOn' {
            Ensure               = 'Present'
            ServerName           = $NetBIOSName
            InstanceName         = 'MSSQLSERVER'
            PsDscRunAsCredential = $SQLCredentials
        }

        SqlServerLogin 'AddNTServiceClusSvc' {
            Ensure               = 'Present'
            Name                 = 'NT SERVICE\ClusSvc'
            LoginType            = 'WindowsUser'
            ServerName           = $NetBIOSName
            InstanceName         = 'MSSQLSERVER'
            PsDscRunAsCredential = $SQLCredentials
        }

        SqlServerPermission 'AddNTServiceClusSvcPermissions' {
            DependsOn            = '[SqlServerLogin]AddNTServiceClusSvc'
            Ensure               = 'Present'
            ServerName           = $NetBIOSName
            InstanceName         = 'MSSQLSERVER'
            Principal            = 'NT SERVICE\ClusSvc'
            Permission           = 'AlterAnyAvailabilityGroup', 'ViewServerState'
            PsDscRunAsCredential = $SQLCredentials
        }

        SqlServerEndpoint 'HADREndpoint' {
            EndPointName         = 'HADR'
            Ensure               = 'Present'
            Port                 = 5022
            ServerName           = $NetBIOSName
            InstanceName         = 'MSSQLSERVER'
            PsDscRunAsCredential = $SQLCredentials
        }

        SqlAGReplica 'AddReplica' {
            Ensure                     = 'Present'
            Name                       = $NetBIOSName
            AvailabilityGroupName      = $AvailabiltyGroupName
            ServerName                 = $NetBIOSName
            InstanceName               = 'MSSQLSERVER'
            PrimaryReplicaServerName   = $PrimaryNetBIOSName
            PrimaryReplicaInstanceName = 'MSSQLSERVER'
            AvailabilityMode           = 'SynchronousCommit'
            FailoverMode               = 'Automatic'
            DependsOn                  = '[SqlAlwaysOnService]EnableAlwaysOn' 
            ProcessOnlyOnActiveNode    = $true
            PsDscRunAsCredential       = $SQLCredentials
        }
    }
}

AddAG -OutputPath 'C:\AWSQuickstart\AddAG' -Credentials $Credentials -SQLCredentials $SQLCredentials -ConfigurationData $ConfigurationData