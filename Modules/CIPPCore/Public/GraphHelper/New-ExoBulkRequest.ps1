function New-ExoBulkRequest {
    <#
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        $tenantid,
        $cmdletArray,
        $useSystemMailbox,
        $Anchor,
        $NoAuthCheck,
        $Select,
        $ReturnWithCommand,
        [switch]$Compliance,
        [switch]$AsApp
    )

    if ((Get-AuthorisedRequest -TenantID $tenantid) -or $NoAuthCheck -eq $True) {
        if ($Compliance.IsPresent) {
            $Resource = 'https://ps.compliance.protection.outlook.com'
        } else {
            $Resource = 'https://outlook.office365.com'
        }
        $Token = Get-GraphToken -Tenantid $tenantid -scope "$Resource/.default" -AsApp:$AsApp.IsPresent

        $Tenant = Get-Tenants -IncludeErrors | Where-Object { $_.defaultDomainName -eq $tenantid -or $_.customerId -eq $tenantid }
        $Headers = @{
            Authorization             = $Token.Authorization
            Prefer                    = 'odata.maxpagesize = 1000;odata.continue-on-error'
            'parameter-based-routing' = $true
            'X-AnchorMailbox'         = $Anchor
        }

        if ($Compliance.IsPresent) {
            # Compliance URL logic (omitted for brevity)
        }

        try {
            if ($Select) { $Select = "`$select=$Select" }
            $URL = "$Resource/adminapi/beta/$($Tenant.customerId)/InvokeCommand?$Select"
            $BatchURL = "$Resource/adminapi/beta/$($Tenant.customerId)/`$batch"

            # Initialize the ID to Cmdlet Name mapping
            $IdToCmdletName = @{}
            $IdToOperationGuid = @{}  # Track operation GUIDs when provided

            # Split the cmdletArray into batches of 10
            $batches = [System.Collections.Generic.List[object]]::new()
            for ($i = 0; $i -lt $cmdletArray.Length; $i += 10) {
                $batches.Add($cmdletArray[$i..[math]::Min($i + 9, $cmdletArray.Length - 1)])
            }

            $ReturnedData = [System.Collections.Generic.List[object]]::new()
            foreach ($batch in $batches) {
                $BatchBodyObj = @{
                    requests = @()
                }
                foreach ($cmd in $batch) {
                    $cmdparams = $cmd.CmdletInput.Parameters
                    if ($cmdparams.Identity) { $Anchor = $cmdparams.Identity }
                    if ($cmdparams.anr) { $Anchor = $cmdparams.anr }
                    if ($cmdparams.User) { $Anchor = $cmdparams.User }
                    if (!$Anchor -or $useSystemMailbox) {
                        $OnMicrosoft = $Tenant.initialDomainName
                        $Anchor = "UPN:SystemMailbox{8cc370d3-822a-4ab8-a926-bb94bd0641a9}@$($OnMicrosoft)"
                    }
                    $Headers['X-AnchorMailbox'] = "APP:SystemMailbox{bb558c35-97f1-4cb9-8ff7-d53741dc928c}@$($tenant.customerId)"
                    $Headers['X-CmdletName'] = $cmd.CmdletInput.CmdletName
                    $Headers['Accept'] = 'application/json; odata.metadata=minimal'
                    $Headers['Accept-Encoding'] = 'gzip'

                    # Use provided OperationGuid if available, otherwise generate one
                    $RequestId = if ($cmd.OperationGuid) {
                        $cmd.OperationGuid
                    } else {
                        [Guid]::NewGuid().ToString()
                    }

                    # Create clean cmdlet object for API (without OperationGuid)
                    $CleanCmd = @{
                        CmdletInput = $cmd.CmdletInput
                    }

                    $BatchRequest = @{
                        url     = $URL
                        method  = 'POST'
                        body    = $CleanCmd
                        headers = $Headers.Clone()
                        id      = $RequestId
                    }
                    $BatchBodyObj['requests'] = $BatchBodyObj['requests'] + $BatchRequest

                    # Map the Request ID to the Cmdlet Name and Operation GUID (if provided)
                    $IdToCmdletName[$RequestId] = $cmd.CmdletInput.CmdletName
                    if ($cmd.OperationGuid) {
                        $IdToOperationGuid[$RequestId] = $cmd.OperationGuid
                    }
                }
                $BatchBodyJson = ConvertTo-Json -InputObject $BatchBodyObj -Depth 10
                $BatchBodyJson = Get-CIPPTextReplacement -TenantFilter $tenantid -Text $BatchBodyJson
                $Results = Invoke-RestMethod $BatchURL -ResponseHeadersVariable responseHeaders -Method POST -Body $BatchBodyJson -Headers $Headers -ContentType 'application/json; charset=utf-8'
                foreach ($Response in $Results.responses) {
                    $ReturnedData.Add($Response)
                }

                Write-Host "Batch #$($batches.IndexOf($batch) + 1) of $($batches.Count) processed"
            }
        } catch {
            # Error handling (omitted for brevity)
        }

        #Write-Information ($responseHeaders | ConvertTo-Json -Depth 10)

        # Process the returned data
        if ($ReturnWithCommand) {
            $FinalData = @{}
            foreach ($item in $ReturnedData) {
                $itemId = $item.id
                $CmdletName = $IdToCmdletName[$itemId]
                $OperationGuid = $IdToOperationGuid[$itemId]  # Will be $null if not provided
                $body = $item.body.PSObject.Copy()

                if ($body.'@adminapi.warnings') {
                    Write-Warning ($body.'@adminapi.warnings' | Out-String)
                }
                if (![string]::IsNullOrEmpty($body.error.details.message) -or ![string]::IsNullOrEmpty($body.error.message)) {
                    if ($body.error.details.message) {
                        $msg = [pscustomobject]@{ error = $body.error.details.message; target = $body.error.details.target }
                    } else {
                        $msg = [pscustomobject]@{ error = $body.error.message; target = $body.error.details.target }
                    }

                    # Add OperationGuid to error if it was provided
                    if ($OperationGuid) {
                        $msg | Add-Member -MemberType NoteProperty -Name 'OperationGuid' -Value $OperationGuid -Force
                    }

                    $body | Add-Member -MemberType NoteProperty -Name 'value' -Value $msg -Force
                } else {
                    # Handle successful operations - add OperationGuid if provided
                    if ($body.value) {
                        # Add GUID to existing results if provided
                        if ($OperationGuid) {
                            if ($body.value -is [array]) {
                                foreach ($val in $body.value) {
                                    $val | Add-Member -MemberType NoteProperty -Name 'OperationGuid' -Value $OperationGuid -Force
                                }
                            } else {
                                $body.value | Add-Member -MemberType NoteProperty -Name 'OperationGuid' -Value $OperationGuid -Force
                            }
                        }
                    } else {
                        # Create success indicators when GUID was provided (caller wants tracking)
                        if ($OperationGuid) {
                            $body | Add-Member -MemberType NoteProperty -Name 'value' -Value ([pscustomobject]@{
                                Success = $true
                                OperationGuid = $OperationGuid
                            }) -Force
                        }
                    }
                }

                $resultValues = $body.value
                foreach ($resultValue in $resultValues) {
                    if (-not $FinalData.ContainsKey($CmdletName)) {
                        $FinalData[$CmdletName] = [System.Collections.Generic.List[object]]::new()
                        $FinalData[$CmdletName].Add($resultValue)
                    } else {
                        $FinalData[$CmdletName].Add($resultValue)
                    }
                }
            }
        } else {
            $FinalData = foreach ($item in $ReturnedData) {
                $OperationGuid = $IdToOperationGuid[$item.id]  # Will be $null if not provided
                $body = $item.body.PSObject.Copy()

                if ($body.'@adminapi.warnings') {
                    Write-Warning ($body.'@adminapi.warnings' | Out-String)
                }
                if (![string]::IsNullOrEmpty($body.error.details.message) -or ![string]::IsNullOrEmpty($body.error.message)) {
                    if ($body.error.details.message) {
                        $msg = [pscustomobject]@{ error = $body.error.details.message; target = $body.error.details.target }
                    } else {
                        $msg = [pscustomobject]@{ error = $body.error.message; target = $body.error.details.target }
                    }

                    # Add OperationGuid to error if it was provided
                    if ($OperationGuid) {
                        $msg | Add-Member -MemberType NoteProperty -Name 'OperationGuid' -Value $OperationGuid -Force
                    }

                    $body | Add-Member -MemberType NoteProperty -Name 'value' -Value $msg -Force
                } else {
                    # Handle successful operations
                    if ($body.value) {
                        # Add GUID to existing results if provided
                        if ($OperationGuid) {
                            if ($body.value -is [array]) {
                                foreach ($val in $body.value) {
                                    $val | Add-Member -MemberType NoteProperty -Name 'OperationGuid' -Value $OperationGuid -Force
                                }
                            } else {
                                $body.value | Add-Member -MemberType NoteProperty -Name 'OperationGuid' -Value $OperationGuid -Force
                            }
                        }
                    } else {
                        # Create success indicators when GUID was provided (caller wants tracking)
                        if ($OperationGuid) {
                            $body | Add-Member -MemberType NoteProperty -Name 'value' -Value ([pscustomobject]@{
                                Success = $true
                                OperationGuid = $OperationGuid
                            }) -Force
                        }
                    }
                }
                $body.value
            }
        }
        return $FinalData

    } else {
        Write-Error 'Not allowed. You cannot manage your own tenant or tenants not under your scope'
    }
}
