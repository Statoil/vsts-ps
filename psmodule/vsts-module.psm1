param()

$AUTHTOKEN = $null



function Get-VSTSReleaseDefinitionIdFromName([string]$Account, [string]$Project, [string]$DefinitionName) {
    $url = (Get-VSTSUrl -Account $Account -Project $Project) + "/_apis/release/definitions"
    
    Write-Host "(d) Fetching release definitions: $url" -ForegroundColor DarkGray
    $definitions = Invoke-RestMethod -Method Get -Uri $url -Headers (Get-VSTSHeaders -Account $Account)

    if ($definitions) {
        Write-Host "(d) Found $($definitions.count) definitions" -ForegroundColor DarkGreen

        $defintion = $definitions.value | where -Property name -like $DefinitionName

        if ($defintion -ne $null) {
            Write-Host "(d) Located definition" -ForegroundColor DarkGreen
            return $defintion.id
        }
    }

    throw "Could not find any release definition with the name $DefinitionName"
}

function Get-VSTSReleaseDefinitionFromId([string]$Account, [string]$Project, [string]$DefinitionId) {
    $url = (Get-VSTSUrl -Account $Account -Project $Project) + "/_apis/release/definitions/$DefinitionId"

    Write-Host "(d) Fetching release definition: $url" -ForegroundColor DarkGray
    $definition = Invoke-RestMethod -Method Get -Uri $url -Headers (Get-VSTSHeaders -Account $Account)

    if ($definition -ne $null) {
        Write-Host "(d) Got definition from id $DefinitionId" -ForegroundColor DarkGreen
    }

    return $definition
}

function Get-VSTSReleaseDefinitionRevision {
    param (
        [Parameter(Mandatory=$true,Position=0)]
        [string]$Account, 
        [Parameter(Mandatory=$true,Position=1)]
        [string]$Project, 
        [Parameter(Mandatory=$true,Position=2)]
        [string]$DefinitionId,
        [Parameter(Mandatory=$true,Position=3)]
        [int]$Revision
    )
    process {
        $url = (Get-VSTSUrl -Account $Account -Project $Project) + "/_apis/release/definitions/$DefinitionId/revisions/$Revision"
        
        Write-Host "(d) Fetching release revision: $url" -ForegroundColor DarkGray
        
        # Seems the latest version doesn't support this request - need to used 3.2-preview.1 api version
        $definition = Invoke-RestMethod -Method Get -Uri $url -Headers (Get-VSTSHeaders -Account $Account -Version "3.2-preview.1")

        if ($definition -ne $null) {
            Write-Host "(d) Got revision $Revision from release definition $DefinitionId" -ForegroundColor DarkGreen
        }

        return $definition
    }
}

function Get-VSTSReleaseDefinition {
    param(
        [Parameter(Mandatory=$true,Position=0)]
        [string]$Account,
        [Parameter(Mandatory=$true,Position=1)]
        [string]$Project,
        [string]$DefinitionName,
        [int]$DefinitionId
    )

    if ([String]::IsNullOrEmpty($DefinitionId)) {
        if ([string]::IsNullOrEmpty($Definition)) {
            throw "No definition set, use either -Definition or -DefinitionId"
        }
        $DefinitionId = Get-VSTSReleaseDefinitionIdFromName -DefinitionName $DefinitionName
    }

    $definitionJson = Get-VSTSReleaseDefinitionFromId -Account $Account -Project $Project -DefinitionId $DefinitionId
    return $definitionJson
}

function Set-VSTSReleaseDefinition([string]$Account, [string]$Project, $Definition) {
    $url = $Definition.url
    Write-Host "(d) Saving definition $($Definition.url)" -ForegroundColor DarkGray
    try {
        $json = $Definition | ConvertTo-Json -Depth 10 
        $newDefinition = Invoke-RestMethod -Method Put -Uri $url -Headers (Get-VSTSHEaders -Account $Account) -Body $json
        Write-Host "(d) Definition saved" -ForegroundColor DarkGreen
        return $newDefinition
    } catch {
        Write-Error $_
    }
}

function Get-VSTSHeaders([string]$Account,[string]$Version="3.2-preview.3") {
    $authToken = Get-VSTSAuth -Account $Account

    $headers = @{
        "Content-Type" = "application/json"; 
        "Authorization" = "Basic $authToken"; 
        "Accept" = "application/json; api-version=$Version"
    }

    return $headers
}

function Set-VSTSAuth {
    param(
        [string]$Account, 
        [string]$Token, 
        [Switch]$SessionOnly
    )
    process{
        $encodedCredentials = [System.Convert]::ToBase64String([System.Text.ASCIIEncoding]::ASCII.GetBytes(":$Token"))
        
        $script:AUTHTOKEN = $encodedCredentials
        
        if (!$SessionOnly.IsPresent) {
            $secureCredentials = ConvertTo-SecureString -String $encodedCredentials -AsPlainText -Force
            $tmpPath = Get-CacheFileName $Account
            
            Write-Host "(d) Saved credentials in tmp file" -ForegroundColor DarkGray
            $secureCredentials | ConvertFrom-SecureString | Out-File $tmpPath
        }
    }
}

function Get-VSTSAuth([string]$Account) {
    if ($script:AUTHTOKEN -ne $null) {
        return $script:AUTHTOKEN
    }

    $tmpFile = Get-CacheFileName $Account

    if (Test-Path $tmpFile) {
        $securedContent = Get-Content $tmpFile
        $secureString = ConvertTo-SecureString -String $securedContent
        $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureString)
        $authToken = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
        
        return $authToken
    }

    throw "No credentials found, use Set-VSTSAuth to generate auth token"
}

function Get-CacheFileName([string]$Account) {
    $encodedAccountName = [System.Convert]::ToBase64String( [System.Text.Encoding]::UTF8.GetBytes($Account))
    $fileName = Join-Path ([io.path]::GetTempPath()) "vsts_$encodedAccountName"
    return $fileName
}

function Get-VSTSUrl([string]$Account, [string]$Project) {
    $baseUrl = "https://$Account.vsrm.visualstudio.com/defaultcollection/$Project"
    return $baseUrl
}

function Is-VSTSAuthSet([String]$Account) {
    try {
        $auth = Get-VSTSAuth -Account $Account
        return $true
    } catch {
        Write-Error $_
        return $false
    }
}

function Sync-VSTSReleaseSteps {
    param( 
        [Parameter(Mandatory=$true,Position=0)]
        [string]$Account,
        [Parameter(Mandatory=$true,Position=1)]
        [string]$Project,
        [string]$DefinitionName,
        [int]$DefinitionId,
        [Parameter(Mandatory=$true,Position=4)]
        [string]$SourceEnv,
        [string[]]$SkipEnvironment
    )
    process {
        
        if ((Is-VSTSAuthSet -Account $Account) -eq $false) {
            return
        }

        $definition = Get-VSTSReleaseDefinition -Account $Account -Project $Project -DefinitionName $DefinitionName -DefinitionId $DefinitionId

        if ($definition -eq $null) {
            throw "Could not retrieve release definition from VSTS"
        }

        $srcEnv = $definition.environments | where -Property name -like $SourceEnv

        foreach ($env in $definition.environments) {
            if ($env.name -eq $srcEnvironmentName) {
                continue
            }

            # Check for skip auto skip variable
            if ($env.variables.psSyncDisabled.value -eq "true") {
                Write-Host "(i) Skipping environment $($env.name) due to presence of sync disabled variable" -ForegroundColor Yellow
                continue
            }

            if ($SkipEnvironment -and ($SkipEnvironment | foreach {$_.ToLower()}).Contains($env.name.ToLower())) {
                Write-Host "(i) Skipping environment $($env.name) due to skip list" -ForegroundColor Yellow
                continue
            }

            Write-Host "(d) Syncing steps in env: $($env.name)" -ForegroundColor DarkGray

            $env.deployPhases = $srcEnv.deployPhases
        }

        $newDef = Set-VSTSReleaseDefinition -Account $Account -Project $Project -Definition $definition
    }
}

##
# THIS IS NOT WORKING AS EXPECTED, NEED MORE INVESTIGATION
# - Restores steps, but missing inputs. 
# - Revision is not found using the latest API version. Might be something "fishy" here..
# - API version where revision can be found, does not support setting deployment phases. 
#
# NEED MORE LOGIC TO COPY STUFF FROM REVISION TO DEFINITION FETCHED WITH LATEST API VERSION
##
function Restore-VSTSReleaseRevision {
    param( 
        [Parameter(Mandatory=$true,Position=0)]
        [string]$Account,
        [Parameter(Mandatory=$true,Position=1)]
        [string]$Project,
        [string]$DefinitionName,
        [int]$DefinitionId,
        [Parameter(Mandatory=$true,Position=4)]
        [int]$Revision
    )

    Write-Host "(WARNING) NOT IMPLEMENTED - ABORTING" -ForegroundColor Red
    return

    if ((Is-VSTSAuthSet -Account $Account) -eq $false) {
        Write-Host "(err) No authentication detected - aborting" -ForegroundColor Red
        return
    }

    $definition = Get-VSTSReleaseDefinition -Account $Account -Project $Project -DefinitionName $DefinitionName -DefinitionId $DefinitionId

    if ($definition -ne $null) {
        Write-Host "(i) Fetching revision data" -ForegroundColor Yellow
        $revisionDefinition = Get-VSTSReleaseDefinitionRevision -Account $Account -Project $Project -DefinitionId $definition.id -Revision $Revision

        # Change the old revision number to the current one so the save goes through.
        # ! Unsure if the secret variables are persisted through this action.
        $revisionDefinition.revision = $definition.revision

        Write-Host "(i) Restoring revision to current version" -ForegroundColor Yellow
        
        $newDefinition = Set-VSTSReleaseDefinition -Account $Account -Project $Project -Definition $revisionDefinition

        if ($newDefinition) {
            Write-Host "(ok) Release definition restored from rev $Revision, new revision number is $($newDefinition.revision)" -ForegroundColor Green
        } else {
            Write-Host "(err) Error restoring release definition from older revision" -ForegroundColor Red
        }
    }
}

Export-ModuleMember -function Sync-VSTSReleaseSteps, Set-VSTSAuth