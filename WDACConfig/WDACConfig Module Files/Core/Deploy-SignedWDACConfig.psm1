Function Deploy-SignedWDACConfig {
    [CmdletBinding(
        SupportsShouldProcess = $true,
        PositionalBinding = $false,
        ConfirmImpact = 'High'
    )]
    Param(
        [ValidatePattern('\.xml$')]
        [ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' }, ErrorMessage = 'The path you selected is not a file path.')]
        [parameter(Mandatory = $true, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)][System.IO.FileInfo[]]$PolicyPaths,

        [Parameter(Mandatory = $false)][System.Management.Automation.SwitchParameter]$Deploy,

        [ValidatePattern('\.cer$')]
        [ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' }, ErrorMessage = 'The path you selected is not a file path.')]
        [parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)][System.IO.FileInfo]$CertPath,

        [ValidateScript({
                # Create an empty array to store the output objects
                [System.String[]]$Output = @()

                # Loop through each certificate that uses RSA algorithm (Because ECDSA is not supported for signing WDAC policies) in the current user's personal store and extract the relevant properties
                foreach ($Cert in (Get-ChildItem -Path 'Cert:\CurrentUser\My' | Where-Object -FilterScript { $_.PublicKey.Oid.FriendlyName -eq 'RSA' })) {

                    # Takes care of certificate subjects that include comma in their CN
                    # Determine if the subject contains a comma
                    if ($Cert.Subject -match 'CN=(?<RegexTest>.*?),.*') {
                        # If the CN value contains double quotes, use split to get the value between the quotes
                        if ($matches['RegexTest'] -like '*"*') {
                            $SubjectCN = ($Element.Certificate.Subject -split 'CN="(.+?)"')[1]
                        }
                        # Otherwise, use the named group RegexTest to get the CN value
                        else {
                            $SubjectCN = $matches['RegexTest']
                        }
                    }
                    # If the subject does not contain a comma, use a lookbehind to get the CN value
                    elseif ($Cert.Subject -match '(?<=CN=).*') {
                        $SubjectCN = $matches[0]
                    }
                    $Output += $SubjectCN
                }

                $Output -contains $_
            }, ErrorMessage = "A certificate with the provided common name doesn't exist in the personal store of the user certificates." )]
        [parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)][System.String]$CertCN,

        [ValidatePattern('\.exe$')]
        [ValidateScript({ Test-Path -Path $_ -PathType 'Leaf' }, ErrorMessage = 'The path you selected is not a file path.')]
        [parameter(Mandatory = $false, ValueFromPipelineByPropertyName = $true, ValueFromPipeline = $true)]
        [System.IO.FileInfo]$SignToolPath,

        [Parameter(Mandatory = $false)]
        [System.Management.Automation.SwitchParameter]$Force,

        [Parameter(Mandatory = $false)][System.Management.Automation.SwitchParameter]$SkipVersionCheck
    )

    begin {
        # Detecting if Verbose switch is used
        $PSBoundParameters.Verbose.IsPresent ? ([System.Boolean]$Verbose = $true) : ([System.Boolean]$Verbose = $false) | Out-Null

        # Importing the $PSDefaultParameterValues to the current session, prior to everything else
        . "$ModuleRootPath\CoreExt\PSDefaultParameterValues.ps1"

        # Importing the required sub-modules
        Write-Verbose -Message 'Importing the required sub-modules'
        Import-Module -FullyQualifiedName "$ModuleRootPath\Shared\Update-self.psm1" -Force
        Import-Module -FullyQualifiedName "$ModuleRootPath\Shared\Get-SignTool.psm1" -Force
        Import-Module -FullyQualifiedName "$ModuleRootPath\Shared\Confirm-CertCN.psm1" -Force
        Import-Module -FullyQualifiedName "$ModuleRootPath\Shared\Write-ColorfulText.psm1" -Force

        # if -SkipVersionCheck wasn't passed, run the updater
        if (-NOT $SkipVersionCheck) { Update-self -InvocationStatement $MyInvocation.Statement }

        #Region User-Configurations-Processing-Validation
        # If any of these parameters, that are mandatory for all of the position 0 parameters, isn't supplied by user
        if (!$SignToolPath -or !$CertPath -or !$CertCN) {
            # Read User configuration file if it exists
            $UserConfig = Get-Content -Path "$UserAccountDirectoryPath\.WDACConfig\UserConfigurations.json" -ErrorAction SilentlyContinue
            if ($UserConfig) {
                # Validate the Json file and read its content to make sure it's not corrupted
                try { $UserConfig = $UserConfig | ConvertFrom-Json }
                catch {
                    Write-Error -Message 'User Configuration Json file is corrupted, deleting it...' -ErrorAction Continue
                    Remove-CommonWDACConfig
                }
            }
        }

        # Get SignToolPath from user parameter or user config file or auto-detect it
        if ($SignToolPath) {
            $SignToolPathFinal = Get-SignTool -SignToolExePath $SignToolPath
        } # If it is null, then Get-SignTool will behave the same as if it was called without any arguments.
        else {
            $SignToolPathFinal = Get-SignTool -SignToolExePath ($UserConfig.SignToolCustomPath ?? $null)
        }

        # If CertPath parameter wasn't provided by user
        if (!$CertPath) {
            if ($UserConfig.CertificatePath) {
                # validate user config values for Certificate Path
                if (Test-Path -Path $($UserConfig.CertificatePath)) {
                    # If the user config values are correct then use them
                    $CertPath = $UserConfig.CertificatePath
                }
                else {
                    throw 'The currently saved value for CertPath in user configurations is invalid.'
                }
            }
            else {
                throw 'CertPath parameter cannot be empty and no valid configuration was found for it.'
            }
        }

        # If CertCN was not provided by user
        if (!$CertCN) {
            if ($UserConfig.CertificateCommonName) {
                # Check if the value in the User configuration file exists and is valid
                if (Confirm-CertCN -CN $($UserConfig.CertificateCommonName)) {
                    # if it's valid then use it
                    $CertCN = $UserConfig.CertificateCommonName
                }
                else {
                    throw 'The currently saved value for CertCN in user configurations is invalid.'
                }
            }
            else {
                throw 'CertCN parameter cannot be empty and no valid configuration was found for it.'
            }
        }
        #Endregion User-Configurations-Processing-Validation

        # Detecting if Confirm switch is used to bypass the confirmation prompts
        if ($Force -and -Not $Confirm) {
            $ConfirmPreference = 'None'
        }
    }

    process {
        foreach ($PolicyPath in $PolicyPaths) {
            # The total number of the main steps for the progress bar to render
            [System.Int16]$TotalSteps = $Deploy ? 4 : 3
            [System.Int16]$CurrentStep = 0

            $CurrentStep++
            Write-Progress -Id 13 -Activity 'Gathering policy details' -Status "Step $CurrentStep/$TotalSteps" -PercentComplete ($CurrentStep / $TotalSteps * 100)

            Write-Verbose -Message "Gathering policy details from: $PolicyPath"
            $Xml = [System.Xml.XmlDocument](Get-Content -Path $PolicyPath)
            [System.String]$PolicyType = $Xml.SiPolicy.PolicyType
            [System.String]$PolicyID = $Xml.SiPolicy.PolicyID
            [System.String]$PolicyName = ($Xml.SiPolicy.Settings.Setting | Where-Object -FilterScript { $_.provider -eq 'PolicyInfo' -and $_.valuename -eq 'Name' -and $_.key -eq 'Information' }).value.string
            [System.String[]]$PolicyRuleOptions = $Xml.SiPolicy.Rules.Rule.Option

            Write-Verbose -Message 'Removing any existing .CIP file of the same policy being signed and deployed if any in the current working directory'
            Remove-Item -Path ".\$PolicyID.cip" -ErrorAction SilentlyContinue

            Write-Verbose -Message 'Checking if the policy type is Supplemental and if so, removing the -Supplemental parameter from the SignerRule command'
            if ($PolicyType -eq 'Supplemental Policy') {

                Write-Verbose -Message 'Policy type is Supplemental'

                # Make sure -User is not added if the UMCI policy rule option doesn't exist in the policy, typically for Strict kernel mode policies
                if ('Enabled:UMCI' -in $PolicyRuleOptions) {
                    Add-SignerRule -FilePath $PolicyPath -CertificatePath $CertPath -Update -User -Kernel
                }
                else {
                    Write-Verbose -Message 'UMCI policy rule option does not exist in the policy, typically for Strict kernel mode policies'
                    Add-SignerRule -FilePath $PolicyPath -CertificatePath $CertPath -Update -Kernel
                }
            }
            else {

                Write-Verbose -Message 'Policy type is Base'

                # Make sure -User is not added if the UMCI policy rule option doesn't exist in the policy, typically for Strict kernel mode policies
                if ('Enabled:UMCI' -in $PolicyRuleOptions) {
                    Add-SignerRule -FilePath $PolicyPath -CertificatePath $CertPath -Update -User -Kernel -Supplemental
                }
                else {
                    Write-Verbose -Message 'UMCI policy rule option does not exist in the policy, typically for Strict kernel mode policies'
                    Add-SignerRule -FilePath $PolicyPath -CertificatePath $CertPath -Update -Kernel -Supplemental
                }
            }

            $CurrentStep++
            Write-Progress -Id 13 -Activity 'Creating CIP file' -Status "Step $CurrentStep/$TotalSteps" -PercentComplete ($CurrentStep / $TotalSteps * 100)

            Write-Verbose -Message 'Setting HVCI to Strict'
            Set-HVCIOptions -Strict -FilePath $PolicyPath

            Write-Verbose -Message 'Removing the Unsigned mode option from the policy rules'
            Set-RuleOption -FilePath $PolicyPath -Option 6 -Delete

            Write-Verbose -Message 'Converting the policy to .CIP file'
            ConvertFrom-CIPolicy -XmlFilePath $PolicyPath -BinaryFilePath "$PolicyID.cip" | Out-Null

            $CurrentStep++
            Write-Progress -Id 13 -Activity 'Signing the policy' -Status "Step $CurrentStep/$TotalSteps" -PercentComplete ($CurrentStep / $TotalSteps * 100)

            # Configure the parameter splat
            $ProcessParams = @{
                'ArgumentList' = 'sign', '/v' , '/n', "`"$CertCN`"", '/p7', '.', '/p7co', '1.3.6.1.4.1.311.79.1', '/fd', 'certHash', ".\$PolicyID.cip"
                'FilePath'     = $SignToolPathFinal
                'NoNewWindow'  = $true
                'Wait'         = $true
                'ErrorAction'  = 'Stop'
            }
            # Hide the SignTool.exe's normal output unless -Verbose parameter was used
            if (!$Verbose) { $ProcessParams['RedirectStandardOutput'] = 'NUL' }

            # Sign the files with the specified cert
            Write-Verbose -Message 'Signing the policy with the specified certificate'
            Start-Process @ProcessParams

            Write-Verbose -Message 'Making sure a .CIP file with the same name is not present in the current working directory'
            Remove-Item -Path ".\$PolicyID.cip" -Force

            Write-Verbose -Message 'Renaming the .p7 file to .cip'
            Rename-Item -Path "$PolicyID.cip.p7" -NewName "$PolicyID.cip" -Force

            if ($Deploy) {

                $CurrentStep++
                Write-Progress -Id 13 -Activity 'Deploying' -Status "Step $CurrentStep/$TotalSteps" -PercentComplete ($CurrentStep / $TotalSteps * 100)

                # Prompt for confirmation before proceeding
                if ($PSCmdlet.ShouldProcess('This PC', 'Deploying the signed policy')) {

                    Write-Verbose -Message 'Deploying the policy'
                    &'C:\Windows\System32\CiTool.exe' --update-policy ".\$PolicyID.cip" -json | Out-Null

                    Write-ColorfulText -Color Lavender -InputText 'policy with the following details has been Signed and Deployed in Enforced Mode:'
                    Write-ColorfulText -Color MintGreen -InputText "PolicyName = $PolicyName"
                    Write-ColorfulText -Color MintGreen -InputText "PolicyGUID = $PolicyID"

                    Write-Verbose -Message 'Removing the .CIP file after deployment'
                    Remove-Item -Path ".\$PolicyID.cip" -Force

                    #Region Detecting Strict Kernel mode policy and removing it from User Configs
                    if ('Enabled:UMCI' -notin $PolicyRuleOptions) {

                        [System.String]$StrictKernelPolicyGUID = Get-CommonWDACConfig -StrictKernelPolicyGUID
                        [System.String]$StrictKernelNoFlightRootsPolicyGUID = Get-CommonWDACConfig -StrictKernelNoFlightRootsPolicyGUID

                        if (($PolicyName -like '*Strict Kernel mode policy Enforced*')) {

                            Write-Verbose -Message 'The deployed policy is Strict Kernel mode'

                            if ($StrictKernelPolicyGUID) {
                                if ($($PolicyID.TrimStart('{').TrimEnd('}')) -eq $StrictKernelPolicyGUID) {

                                    Write-Verbose -Message 'Removing the GUID of the deployed Strict Kernel mode policy from the User Configs'
                                    Remove-CommonWDACConfig -StrictKernelPolicyGUID | Out-Null
                                }
                            }
                        }
                        elseif (($PolicyName -like '*Strict Kernel No Flights mode policy Enforced*')) {

                            Write-Verbose -Message 'The deployed policy is Strict Kernel No Flights mode'

                            if ($StrictKernelNoFlightRootsPolicyGUID) {
                                if ($($PolicyID.TrimStart('{').TrimEnd('}')) -eq $StrictKernelNoFlightRootsPolicyGUID) {

                                    Write-Verbose -Message 'Removing the GUID of the deployed Strict Kernel No Flights mode policy from the User Configs'
                                    Remove-CommonWDACConfig -StrictKernelNoFlightRootsPolicyGUID | Out-Null
                                }
                            }
                        }
                    }
                    #Endregion Detecting Strict Kernel mode policy and removing it from User Configs
                }
            }
            else {
                Write-ColorfulText -Color Lavender -InputText 'policy with the following details has been Signed and is ready for deployment:'
                Write-ColorfulText -Color MintGreen -InputText "PolicyName = $PolicyName"
                Write-ColorfulText -Color MintGreen -InputText "PolicyGUID = $PolicyID"
            }
            Write-Progress -Id 13 -Activity 'Complete.' -Completed
        }
    }

    <#
.SYNOPSIS
    Signs and Deploys WDAC policies, accepts signed or unsigned policies and deploys them
.LINK
    https://github.com/HotCakeX/Harden-Windows-Security/wiki/Deploy-SignedWDACConfig
.DESCRIPTION
    Using official Microsoft methods, Signs and Deploys WDAC policies, accepts signed or unsigned policies and deploys them (Windows Defender Application Control)
.COMPONENT
    Windows Defender Application Control, ConfigCI PowerShell module
.FUNCTIONALITY
    Using official Microsoft methods, Signs and Deploys WDAC policies, accepts signed or unsigned policies and deploys them (Windows Defender Application Control)
.PARAMETER CertPath
    Path to the certificate .cer file
.PARAMETER PolicyPaths
    Path to the policy xml files that are going to be signed
.PARAMETER CertCN
    Certificate common name
.PARAMETER SignToolPath
    Path to the SignTool.exe - optional parameter
.PARAMETER Deploy
    Indicates that the cmdlet will deploy the signed policy on the current system
.PARAMETER Force
    Indicates that the cmdlet will bypass the confirmation prompts
.PARAMETER SkipVersionCheck
    Can be used with any parameter to bypass the online version check - only to be used in rare cases
.INPUTS
    System.String
    System.String[]
    System.Management.Automation.SwitchParameter
.OUTPUTS
    System.String
#>
}

# Importing argument completer ScriptBlocks
. "$ModuleRootPath\Resources\ArgumentCompleters.ps1"
Register-ArgumentCompleter -CommandName 'Deploy-SignedWDACConfig' -ParameterName 'CertCN' -ScriptBlock $ArgumentCompleterCertificateCN
Register-ArgumentCompleter -CommandName 'Deploy-SignedWDACConfig' -ParameterName 'PolicyPaths' -ScriptBlock $ArgumentCompleterPolicyPaths
Register-ArgumentCompleter -CommandName 'Deploy-SignedWDACConfig' -ParameterName 'CertPath' -ScriptBlock $ArgumentCompleterCerFilePathsPicker
Register-ArgumentCompleter -CommandName 'Deploy-SignedWDACConfig' -ParameterName 'SignToolPath' -ScriptBlock $ArgumentCompleterExeFilePathsPicker

# SIG # Begin signature block
# MIILkgYJKoZIhvcNAQcCoIILgzCCC38CAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCwRTLbYR2tyMkq
# Pwz7so9rkqBTBLu3TVqiK/UjQ3VBqKCCB9AwggfMMIIFtKADAgECAhMeAAAABI80
# LDQz/68TAAAAAAAEMA0GCSqGSIb3DQEBDQUAME8xEzARBgoJkiaJk/IsZAEZFgNj
# b20xIjAgBgoJkiaJk/IsZAEZFhJIT1RDQUtFWC1DQS1Eb21haW4xFDASBgNVBAMT
# C0hPVENBS0VYLUNBMCAXDTIzMTIyNzExMjkyOVoYDzIyMDgxMTEyMTEyOTI5WjB5
# MQswCQYDVQQGEwJVSzEeMBwGA1UEAxMVSG90Q2FrZVggQ29kZSBTaWduaW5nMSMw
# IQYJKoZIhvcNAQkBFhRob3RjYWtleEBvdXRsb29rLmNvbTElMCMGCSqGSIb3DQEJ
# ARYWU3B5bmV0Z2lybEBvdXRsb29rLmNvbTCCAiIwDQYJKoZIhvcNAQEBBQADggIP
# ADCCAgoCggIBAKb1BJzTrpu1ERiwr7ivp0UuJ1GmNmmZ65eckLpGSF+2r22+7Tgm
# pEifj9NhPw0X60F9HhdSM+2XeuikmaNMvq8XRDUFoenv9P1ZU1wli5WTKHJ5ayDW
# k2NP22G9IPRnIpizkHkQnCwctx0AFJx1qvvd+EFlG6ihM0fKGG+DwMaFqsKCGh+M
# rb1bKKtY7UEnEVAsVi7KYGkkH+ukhyFUAdUbh/3ZjO0xWPYpkf/1ldvGes6pjK6P
# US2PHbe6ukiupqYYG3I5Ad0e20uQfZbz9vMSTiwslLhmsST0XAesEvi+SJYz2xAQ
# x2O4n/PxMRxZ3m5Q0WQxLTGFGjB2Bl+B+QPBzbpwb9JC77zgA8J2ncP2biEguSRJ
# e56Ezx6YpSoRv4d1jS3tpRL+ZFm8yv6We+hodE++0tLsfpUq42Guy3MrGQ2kTIRo
# 7TGLOLpayR8tYmnF0XEHaBiVl7u/Szr7kmOe/CfRG8IZl6UX+/66OqZeyJ12Q3m2
# fe7ZWnpWT5sVp2sJmiuGb3atFXBWKcwNumNuy4JecjQE+7NF8rfIv94NxbBV/WSM
# pKf6Yv9OgzkjY1nRdIS1FBHa88RR55+7Ikh4FIGPBTAibiCEJMc79+b8cdsQGOo4
# ymgbKjGeoRNjtegZ7XE/3TUywBBFMf8NfcjF8REs/HIl7u2RHwRaUTJdAgMBAAGj
# ggJzMIICbzA8BgkrBgEEAYI3FQcELzAtBiUrBgEEAYI3FQiG7sUghM++I4HxhQSF
# hqV1htyhDXuG5sF2wOlDAgFkAgEIMBMGA1UdJQQMMAoGCCsGAQUFBwMDMA4GA1Ud
# DwEB/wQEAwIHgDAMBgNVHRMBAf8EAjAAMBsGCSsGAQQBgjcVCgQOMAwwCgYIKwYB
# BQUHAwMwHQYDVR0OBBYEFOlnnQDHNUpYoPqECFP6JAqGDFM6MB8GA1UdIwQYMBaA
# FICT0Mhz5MfqMIi7Xax90DRKYJLSMIHUBgNVHR8EgcwwgckwgcaggcOggcCGgb1s
# ZGFwOi8vL0NOPUhPVENBS0VYLUNBLENOPUhvdENha2VYLENOPUNEUCxDTj1QdWJs
# aWMlMjBLZXklMjBTZXJ2aWNlcyxDTj1TZXJ2aWNlcyxDTj1Db25maWd1cmF0aW9u
# LERDPU5vbkV4aXN0ZW50RG9tYWluLERDPWNvbT9jZXJ0aWZpY2F0ZVJldm9jYXRp
# b25MaXN0P2Jhc2U/b2JqZWN0Q2xhc3M9Y1JMRGlzdHJpYnV0aW9uUG9pbnQwgccG
# CCsGAQUFBwEBBIG6MIG3MIG0BggrBgEFBQcwAoaBp2xkYXA6Ly8vQ049SE9UQ0FL
# RVgtQ0EsQ049QUlBLENOPVB1YmxpYyUyMEtleSUyMFNlcnZpY2VzLENOPVNlcnZp
# Y2VzLENOPUNvbmZpZ3VyYXRpb24sREM9Tm9uRXhpc3RlbnREb21haW4sREM9Y29t
# P2NBQ2VydGlmaWNhdGU/YmFzZT9vYmplY3RDbGFzcz1jZXJ0aWZpY2F0aW9uQXV0
# aG9yaXR5MA0GCSqGSIb3DQEBDQUAA4ICAQA7JI76Ixy113wNjiJmJmPKfnn7brVI
# IyA3ZudXCheqWTYPyYnwzhCSzKJLejGNAsMlXwoYgXQBBmMiSI4Zv4UhTNc4Umqx
# pZSpqV+3FRFQHOG/X6NMHuFa2z7T2pdj+QJuH5TgPayKAJc+Kbg4C7edL6YoePRu
# HoEhoRffiabEP/yDtZWMa6WFqBsfgiLMlo7DfuhRJ0eRqvJ6+czOVU2bxvESMQVo
# bvFTNDlEcUzBM7QxbnsDyGpoJZTx6M3cUkEazuliPAw3IW1vJn8SR1jFBukKcjWn
# aau+/BE9w77GFz1RbIfH3hJ/CUA0wCavxWcbAHz1YoPTAz6EKjIc5PcHpDO+n8Fh
# t3ULwVjWPMoZzU589IXi+2Ol0IUWAdoQJr/Llhub3SNKZ3LlMUPNt+tXAs/vcUl0
# 7+Dp5FpUARE2gMYA/XxfU9T6Q3pX3/NRP/ojO9m0JrKv/KMc9sCGmV9sDygCOosU
# 5yGS4Ze/DJw6QR7xT9lMiWsfgL96Qcw4lfu1+5iLr0dnDFsGowGTKPGI0EvzK7H+
# DuFRg+Fyhn40dOUl8fVDqYHuZJRoWJxCsyobVkrX4rA6xUTswl7xYPYWz88WZDoY
# gI8AwuRkzJyUEA07IYtsbFCYrcUzIHME4uf8jsJhCmb0va1G2WrWuyasv3K/G8Nn
# f60MsDbDH1mLtzGCAxgwggMUAgEBMGYwTzETMBEGCgmSJomT8ixkARkWA2NvbTEi
# MCAGCgmSJomT8ixkARkWEkhPVENBS0VYLUNBLURvbWFpbjEUMBIGA1UEAxMLSE9U
# Q0FLRVgtQ0ECEx4AAAAEjzQsNDP/rxMAAAAAAAQwDQYJYIZIAWUDBAIBBQCggYQw
# GAYKKwYBBAGCNwIBDDEKMAigAoAAoQKAADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGC
# NwIBBDAcBgorBgEEAYI3AgELMQ4wDAYKKwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQx
# IgQg9aAt62DFk68FgRSohKMBdVvji69lOf+ictPC11HAUVIwDQYJKoZIhvcNAQEB
# BQAEggIAg1LFclDMPHNRdb+BpL6gjEd+SfOHpFgakdnfW9VBQrAgpdL+wmRgOuCb
# ImKNsUPE885yVWvOxz+DG6WpNriN872boD8ifZEzbjn0K6yng0NVg/f8Zglo/DXh
# 2Onej6w2EKsJXuHLXR+QCxa4E6dt4NL1+Aylkzc0CprIoCuyftCA3p/FB21IZZO2
# jT10J6THUnDwbh+h2wtwOyw5WaycjbeYSmgyGAbU2Ci3a44XWXhZmE016iKS2GQF
# ovRu9n3xLpd/wd9ROLsWjTw6mCtG8nBCyS9f0RPRHgnA9T/+WTJp93cBjwCJ8ptt
# hYOeoYzKn1xSBg1SD0WU1Db5IRf8mTIYs0zkWwma4LVujGE+4dQjt9gYqlyzLYPF
# bWskeNuTooyCBl130H6dC6lJGim3z2LYGNp252gVrXmwx33AJxUawPD587PDVnD+
# MSTZ0sLTDSjTpxC9/gQvqLVr4ZLWz/4L+PHqzDB04b/1zmdNNlnsHpTZ1rraPdJS
# xCeLI4FiwIKVnqGzdH4lWqKyw4OSProWjrJLYQA2Ezgt/IWqIekftykphq+k1omr
# bu5q45xpQx6h1PUW2A7o+WgHmHu1Ysoi4qw0s4artkS2clWxXrK8r/+BpBhFTKen
# dntssYtVpyh9d2Qk55rwMeL42pPZvbGGEb1PakCypyaGJQUhMHM=
# SIG # End signature block