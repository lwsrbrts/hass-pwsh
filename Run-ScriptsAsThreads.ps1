# Set up some stuff we only need to do once.
# Set the culture to British English, since I'm British.
$CultureInfo = New-Object System.Globalization.CultureInfo("en-GB")
[System.Threading.Thread]::CurrentThread.CurrentCulture = $CultureInfo
[System.Threading.Thread]::CurrentThread.CurrentUICulture = $CultureInfo

# Path to options.json file - this is the file that's placed/mapped/linked in to the running container.
$OPTIONS_FILE = '/data/options.json'
# Read and convert the JSON file to a PowerShell object - we'll use these to get data from the user for use later.
$OPTIONS = Get-Content $OPTIONS_FILE | ConvertFrom-Json

# Throttle Limit defines the number of scripts that will be started as threads by *this* script.
# Bear in mind that if the `Scripts` list's first n scripts run as infinite loops, any scripts over
# the Throttle Limit will never start (and will spam the logs too). So you'll either need to increase
# the Throttle Limit, or have the other scripts start (and complete) before your infinite looping scripts.
$ThreadThrottleLimit = [int]$OPTIONS.threads

# Colours for banner information during startup etc.
$green = $PSStyle.Foreground.Green
$reset = $PSStyle.Reset

# We still want to limit the number of scripts.
if ($OPTIONS.scripts.length -gt 10) {
    throw "Scripts are limited to a maximum of 10 at a single time."
}

# /mnt/data/supervisor/addons/data/local_pwsh is what's mapped to the container and where options.json lives.
# We want the share folder to map to the container so the user places their scripts there.
$scriptLocation = '/share/pwsh/'
if (!(Test-Path $scriptLocation)) {
    $FolderBanner = @"
${green}
#####################################
## Creating /share/pwsh folder...  ##
#####################################

#########################################################
## Since the folder has just been created, the script  ##
## will stop here. Add your scripts and configure the  ##
## add-on now.                                         ##
#########################################################${reset}
"@
    $FolderBanner
    New-Item -Path $scriptLocation -ItemType Directory > $null
    Exit 0
}

# Doing this forces the user to know and set what scripts will run. Just banging them in a folder ain't good.
$scripts = $OPTIONS.scripts

# A way to understand what log is associated with what script.
$jobColours = @{}
$randomisedColours = $PSStyle.Background.PSObject.Properties.Name | Where-Object { $_ -notmatch "Bright" } | Sort-Object { Get-Random }
$i = 0

# Loop through each script and start a thread job for each one
foreach ($script in $scripts) {
        
    $validPath = Test-Path -Path "$scriptLocation$($script.filename)" -PathType Leaf

    if ($validPath) {
        $thisScript = Get-Item -Path "$scriptLocation$($script.filename)"
        try {
            $job = Start-ThreadJob -FilePath $thisScript.FullName -Name $thisScript.BaseName -StreamingHost $Host -ErrorAction Break -ThrottleLimit $ThreadThrottleLimit

            $randomColour = $randomisedColours[$i]
            $jobColours[$job.Name] = $randomColour  # Store the job name and its associated colour
            $i++
            if ($i -eq 8) { $i = 0 }
        }
        catch {
            "$($PSStyle.Foreground.Red)Unable to start the thread for: {0}$($PSStyle.Reset)" -f $script.filename
            $i++
            if ($i -eq 8) { $i = 0 }
        }
    }
    else {
        "$($PSStyle.Foreground.Red)Unable to find a filename: {0}$($PSStyle.Reset)" -f $script.filename
    }
}

$jobCount = (Get-Job).Count

if ($jobCount -eq 0) {
    $NoJobsBanner = @"
${green}
##################################################
## No thread jobs were added. Did you forget to ##
## add your scripts or declare them in the      ##
## configuration?                               ##
##################################################
${reset}
"@
    $NoJobsBanner
    Exit 0
}
else {
    $StartupBanner = @"
${green}
######################
## PowerShell $($PSVersionTable.PSVersion.ToString()) ##
##                  ##
## Jobs are running ##
## ThrottleLimit: $ThreadThrottleLimit ##
## $(Get-Date -UFormat '%d/%m/%Y %H:%M') ##
######################
${reset}
"@
    $StartupBanner

    # Deals with the case where we receive multiple lines or a single line of output from Receive-Job.
    function Out-JobData {
        param (
            [Parameter(Mandatory = $true)]
            $data,
            
            [Parameter(Mandatory = $true)]
            [string]$jobName,
    
            [Parameter(Mandatory = $true)]
            [string]$jobColour
        )
        if ($data -is [array]) {
            for ($i = 0; $i -lt $data.Count; $i++) {
                "$($PSStyle.Background.$jobColour)$($jobName)$($PSStyle.Reset): {0}" -f $data[$i]
            }
        }
        else {
            "$($PSStyle.Background.$jobColour)$($jobName)$($PSStyle.Reset): {0}" -f $data
        }
    }
}

while ($jobs = Get-Job) {
    foreach ($job in $jobs) {
        $jobColour = $jobColours[$job.Name]
        switch ($job.State) {
            { ($_ -eq 'Completed') -or ($_ -eq 'Stopped') -or ($_ -eq 'Failed') } {
                if ($job.HasMoreData) {
                    $data = Receive-Job -Job $job
                    Out-JobData -data $data -jobName $job.Name -jobColour $jobColour
                }
                else {
                    "$($PSStyle.Background.$jobColour)$($job.name)$($PSStyle.Reset): {0}{1}{2}" -f 'Done. Removing this ', $job.State.ToUpper(), " job."
                    Remove-Job -Job $job > $null
                }            
            }
            'Running' {
                if ($job.HasMoreData) {
                    $data = Receive-Job -Job $job
                    Out-JobData -data $data -jobName $job.Name -jobColour $jobColour
                }

            }
            'NotStarted' {
                "$($PSStyle.Background.$jobColour)$($job.name)$($PSStyle.Reset): {0}" -f "This job hasn't started yet, waiting for a job slot (Throttle Limit!)..."
                Continue
            }
            Default {
                if ($job.HasMoreData) {
                    $data = Receive-Job -Job $job
                    Out-JobData -data $data -jobName $job.Name -jobColour $jobColour
                }
                else {
                    "$($PSStyle.Background.$jobColour)$($job.name)$($PSStyle.Reset): {0}{1}{2}" -f 'Stopping this ', $job.State.ToUpper(), " job."
                    Stop-Job -Job $job > $null
                } 
            }
        }
    }
    Start-Sleep -Seconds 10
}

$CompleteBanner = @"
${green}#######################
##  HASS PowerShell  ##
## All jobs complete ##
## $(Get-Date -UFormat '%d/%m/%Y %H:%M')  ##
#######################${reset}
"@

$CompleteBanner