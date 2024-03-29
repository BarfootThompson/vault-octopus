Import-Module CredentialManager
function Get-Hash {
param(
    [string]$s
)
    $utf8 = new-object Text.UTF8Encoding
    [byte[]]$bytes = $utf8.GetBytes($s)
    $ms = [io.memorystream]$bytes
    return (Get-FileHash -InputStream $ms).Hash.Substring(0,8)
}

function Split-SecretPath {
param(
    [string]$path
)
    $tokens = @($path -split ":" | Foreach-Object { $_.Trim() })
    if ($tokens.Length -gt 2) {
        "$path contains more that one ':'. Check 'Paths to secret' parameter" | Write-Error
        exit -1
    }
    if ($tokens.Length -eq 2) {
        $explicit = $true
        $label = $tokens[0]
        $value = $tokens[1]
    }
    if ($tokens.Length -eq 1) {
        $explicit = $false
        $label = Get-Hash $tokens[0]
        $value = $tokens[0]
    }

   if ("#{engineVersion}" -eq "v1") {
       return "{'label': '$label', 'path': '$value', 'explicit': '$explicit'}" | ConvertFrom-Json
   } elseif ("#{engineVersion}" -eq "v2") {
       $tokens = @($value -split '\|' | Foreach-Object { $_.Trim() })
       if ($tokens.Length -ne 2 ) {
           "$value does not contain exactly one '|'. Check 'Paths to secret' parameter" | Write-Error
           exit -1
       }
       $engine = $tokens[0]
       $value = $tokens[1]
       return "{'label': '$label', 'engine': '$engine', 'path': '$value', 'explicit': '$explicit'}" | ConvertFrom-Json
   } else {
       "Vault secret engine version is #{engineVersion}. Only v1 or v2 are expected" | Write-Error
       exit -1
   }
}

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

"Vault Url: #{vaultUrl}" | Write-Host
if ("#{token}" -ne "##{token}") {
    "Using supplied Vault Token" | Write-Host
    $vault_token = "#{token}"
} else {
    if ("#{useCredentialManger}" -eq "True") {
       "Getting Role Id and Secret Id from Windows Credential Manager" | Write-Host
        $vault_role_id = (Get-StoredCredential -Target "#{roleId}" -AsCredentialObject).Password
        $vault_secret_id = (Get-StoredCredential -Target "#{secretId}" -AsCredentialObject).Password
    } else {
        $vault_role_id = "#{roleId}"
        $vault_secret_id = "#{secretId}"
    }
    $payload = "{`"role_id`":`"$vault_role_id`",`"secret_id`":`"$vault_secret_id`"}"
    "Obtaining token with AppRole" | Write-Host
    $res = Invoke-WebRequest -Body $payload  "#{vaultUrl}/v1/auth/approle/login" -Method post -UseBasicParsing
    $vault_token = ($res.Content | ConvertFrom-Json).auth.client_token
}

$path = @("#{path}" -split "`n" | Foreach-Object { $_.Trim() })
$res = $path | Foreach-Object {
    if (![string]::IsNullOrWhiteSpace($_)) {
        $current = Split-SecretPath $_
        "Obtaining secret from $($current.path)" | Write-Host

        if ("#{engineVersion}" -eq "v1") {
            $secret = ((Invoke-WebRequest -Headers @{"X-Vault-Token"="$vault_token"}  "#{vaultUrl}/v1/$($current.path)" -Method get -UseBasicParsing).Content | ConvertFrom-Json).data
        } elseif ("#{engineVersion}" -eq "v2") {
            $secret = ((Invoke-WebRequest -Headers @{"X-Vault-Token"="$vault_token"}  "#{vaultUrl}/v1/$($current.engine)/data/$($current.path)" -Method get -UseBasicParsing).Content | ConvertFrom-Json).data.data
        } else {
            "Vault secret engine version is #{engineVersion}. Only v1 or v2 are expected" | Write-Error
            exit -1
        }
        $secret.psobject.properties | Foreach-Object {
            [pscustomobject]@{
                label = $current.label
                explicit = $current.explicit
                name = $_.Name
                value = $_.value
            }
        }
    }
}

if ("#{token}" -ne "##{token}") {
    if ("#{renew}" -eq "True") {
       "Renewing token" | Write-Host
        Invoke-WebRequest -Headers @{"X-Vault-Token"="$vault_token"} "#{vaultUrl}/v1/auth/token/renew-self" -Method post -UseBasicParsing | Out-Null
    }
} else {
   "Revoking token" | Write-Host
    Invoke-WebRequest -Headers @{"X-Vault-Token"="$vault_token"} "#{vaultUrl}/v1/auth/token/revoke-self" -Method post -UseBasicParsing | Out-Null
}

$res | Foreach-Object {
    if ("#{resultName}" -ne "##{resultName}") {
        $prefix = "#{resultName}."
    } else {
        $prefix = ""
    }

    if (($path.Length -eq 1) -and ($_.explicit -eq "False")) {
        $label = ""
    } else {
        $label = "$($_.label)."
    }

    $name = $prefix + $label + $_.name

    "Writing ##{Octopus.Action[#{Octopus.Step.Name}].Output.$name}" | Write-Host
    if ($sensitiveOutputVariablesSupported -and !("#{notsensitive}" -eq "True")) {
        Set-OctopusVariable -name $name -value $_.value -sensitive
    } else {
        Set-OctopusVariable -name $name -value $_.value
    }
}
