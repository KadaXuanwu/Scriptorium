# The PC's files (docs/QUEUE.md, The PC's files): what every project that Scriptorium runs on this PC shares. The
# account register with its lines and guards, each worker's own entry (a worker's number is the PC's), and the
# accounts' usage, out and access records. Dot-sourced through project.ps1; only definitions.

. (Join-Path $PSScriptRoot 'platform.ps1')

# The folder, one for the PC's user: %LOCALAPPDATA% on Windows, ~/Library/Application Support on macOS, ~/.local/share
# on Linux. A test sets another before it loads this file: a folder that is set stays.
if (-not $PcDir) {
    # DoNotVerify: on Linux the folder may not be there yet, and without it the path comes back empty.
    $PcDir = Join-Path ([Environment]::GetFolderPath('LocalApplicationData', 'DoNotVerify')) 'Scriptorium'
}
# The keys of the settings that are the PC's. Every other key is the project's own.
$PcKeys = @('accounts', 'keep', 'workers', 'order', 'away')
# The accounts' records, which the workers of every project write.
$PcRecords = @('usage.json', 'out.json', 'access.json')

# A lock of the PC's files, for every script of every project: 'Settings' from a read of the settings to their save,
# 'Usage' for the accounts' records. The same thread may take it again.
function Enter-PcLock([string] $name) {
    $lock = New-Object System.Threading.Mutex($false, "Local\Scriptorium-$name")
    try {
        [void]$lock.WaitOne()
    } catch [System.Threading.AbandonedMutexException] {
        # Its last holder ended without a release: the lock is this caller's now.
    }
    return $lock
}

function Exit-PcLock($lock) {
    $lock.ReleaseMutex()
    $lock.Dispose()
}

# A JSON file: $null when there is none. A file that does not parse throws: an unreadable register must never read as
# an empty one (a disabled worker would read as enabled, and a save would write an empty register).
function Read-JsonFile([string] $file) {
    $text = $null
    for ($try = 1; ; $try++) {
        if (-not (Test-Path $file)) {
            # A save takes the file away for an instant, while its new text still waits beside it (Save-JsonFile):
            # 27 of 900 reads found none (measured). Wait for the save; then look once more before this is no file.
            if ((Test-Path "$file.tmp") -and $try -lt 40) {
                Start-Sleep -Milliseconds 25
                continue
            }
            if (-not (Test-Path $file)) {
                return $null
            }
        }
        try {
            $text = Get-Content $file -Raw -Encoding UTF8 -ErrorAction Stop
            break
        } catch {
            # A save holds the file for a moment: read again.
            if ($try -ge 40) {
                throw
            }
            Start-Sleep -Milliseconds 25
        }
    }
    if (-not "$text".Trim()) {
        throw "$file is empty"
    }
    try {
        return $text | ConvertFrom-Json
    } catch {
        throw "$file does not parse: $_"
    }
}

# Written whole beside the file, then put in its place: no reader gets half a file, and none finds the file missing.
# Not a move with -Force: that takes the old file away first, and 576 of 11 000 reads then found none (measured), which
# reads as an empty register. A reader that has the file open for a moment refuses the replace: try again.
function Save-JsonFile([string] $file, $value) {
    New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null
    $value | ConvertTo-Json -Depth 8 | Set-Content "$file.tmp" -Encoding utf8
    for ($try = 1; ; $try++) {
        try {
            if (Test-Path $file) {
                [System.IO.File]::Replace("$file.tmp", $file, [NullString]::Value)
            } else {
                [System.IO.File]::Move("$file.tmp", $file)
            }
            return
        } catch {
            if ($try -ge 40) {
                throw
            }
            Start-Sleep -Milliseconds 25
        }
    }
}

# Sets a property of an object from JSON. Not Add-Member: it reads a name of digits (a worker's number) as a member
# type and refuses it.
function Set-JsonProperty($object, [string] $name, $value) {
    $object.PSObject.Properties.Remove($name)
    $object.PSObject.Properties.Add((New-Object System.Management.Automation.PSNoteProperty($name, $value)))
}

# Gives $to each property of $from that it lacks.
function Copy-Missing($to, $from) {
    foreach ($property in $from.PSObject.Properties) {
        if (-not $to.PSObject.Properties[$property.Name]) {
            Set-JsonProperty $to $property.Name $property.Value
        }
    }
}

# The PC's part of the settings: an empty object while the PC has none.
function Read-PcSettings {
    $pc = Read-JsonFile (Join-Path $PcDir 'settings.json')
    if ($pc) {
        return $pc
    }
    return [pscustomobject]@{}
}

# An account's login folder as one text to compare: '' is the command-line login.
function Get-FolderKey([string] $configDir) {
    return $configDir.Replace('\', '/').TrimEnd('/').ToLowerInvariant()
}

# The PC's settings ($pc) with the PC keys of a project's settings ($own) merged in (Move-PcSettings). Where two
# projects do not disagree, the result is the same in any order of the projects.
# - `accounts`: one entry for each login folder, not for each name. An entry of a folder that the PC has adds its uses
#   and only the fields that the PC's entry lacks. Any other entry goes in under its name, with a number after it when
#   another folder has that name.
# - `keep` and `workers`: only what the PC lacks, field by field for a worker's entry.
function Merge-PcSettings($pc, $own) {
    if ($own.accounts) {
        if (-not $pc.accounts) {
            Set-JsonProperty $pc 'accounts' ([pscustomobject]@{})
        }
        foreach ($entry in $own.accounts.PSObject.Properties) {
            $key = Get-FolderKey ([string]$entry.Value.configDir)
            $match = $pc.accounts.PSObject.Properties | Where-Object { (Get-FolderKey ([string]$_.Value.configDir)) -eq $key } | Select-Object -First 1
            if ($match) {
                Copy-Missing $match.Value $entry.Value
                $uses = @(@($match.Value.uses) + @($entry.Value.uses) | Where-Object { $_ } | Select-Object -Unique)
                Set-JsonProperty $match.Value 'uses' ([object[]]$uses)
            } else {
                $name = $entry.Name
                $number = 2
                while ($pc.accounts.PSObject.Properties[$name]) {
                    $name = "$($entry.Name)-$number"
                    $number++
                }
                Set-JsonProperty $pc.accounts $name $entry.Value
            }
        }
    }
    foreach ($key in @('keep', 'workers')) {
        if (-not $own.$key) {
            continue
        }
        if (-not $pc.$key) {
            Set-JsonProperty $pc $key ([pscustomobject]@{})
        }
        foreach ($entry in $own.$key.PSObject.Properties) {
            $mine = $pc.$key.PSObject.Properties[$entry.Name]
            if (-not $mine) {
                Set-JsonProperty $pc.$key $entry.Name $entry.Value
            } elseif ($key -eq 'workers') {
                Copy-Missing $mine.Value $entry.Value
            }
        }
    }
    return $pc
}

# Whether a project's own settings still hold a key of the PC's.
function Test-PcKeys($own) {
    return [bool]($own -and @($PcKeys | Where-Object { $null -ne $own.$_ }).Count)
}

# Moves the PC keys that a project's file still holds into the PC's file: a project from before the PC's files, or an
# edit by hand. Under the PC's lock, with both files read inside it, so it is safe to run twice and from two scripts
# at once. The PC's file is saved first: a stop between the two saves leaves the keys in both, and the next call
# merges them again to the same result.
# A script from before the PC's files that still runs (a run in progress ends on its old code) reads the project's
# file without them from then on: default lines and the command-line login, until it restarts.
function Move-PcSettings([string] $main) {
    $file = Join-Path $main '.queue/settings.json'
    $lock = Enter-PcLock 'Settings'
    try {
        $own = Read-JsonFile $file
        if (-not (Test-PcKeys $own)) {
            return
        }
        Save-JsonFile (Join-Path $PcDir 'settings.json') (Merge-PcSettings (Read-PcSettings) $own)
        foreach ($key in $PcKeys) {
            $own.PSObject.Properties.Remove($key)
        }
        Save-JsonFile $file $own
    } finally {
        Exit-PcLock $lock
    }
}

# Moves the accounts' records that a project's folder still holds into the PC's folder, under the lock of those
# files. For each account the newer record (`at`) goes on, with what only the other one has: a usage window (only a
# Fable run reads the Fable week), a refused model. A record that does not parse is dropped: each is read again at no
# cost.
function Move-PcRecords([string] $main) {
    $found = @($PcRecords | Where-Object { Test-Path (Join-Path $main ".queue/$_") })
    if (-not $found.Count) {
        return
    }
    $lock = Enter-PcLock 'Usage'
    try {
        foreach ($name in $found) {
            $from = Join-Path $main ".queue/$name"
            $to = Join-Path $PcDir $name
            $old = $null
            $pc = $null
            try {
                $old = Read-JsonFile $from
                $pc = Read-JsonFile $to
            } catch {
            }
            if ($old) {
                if (-not $pc) {
                    $pc = [pscustomobject]@{}
                }
                foreach ($entry in $old.PSObject.Properties) {
                    $mine = $pc.PSObject.Properties[$entry.Name]
                    $first = $entry.Value
                    if ($mine) {
                        $second = $mine.Value
                        if ([long]$second.at -ge [long]$first.at) {
                            $first, $second = $second, $first
                        }
                        Copy-Missing $first $second
                    }
                    Set-JsonProperty $pc $entry.Name $first
                }
                Save-JsonFile $to $pc
            }
            Remove-Item $from -ErrorAction SilentlyContinue
        }
    } finally {
        Exit-PcLock $lock
    }
}

# What a script does once at its start: the PC's folder is there, and nothing of the PC's is left in the project.
function Initialize-Pc([string] $main) {
    New-Item -ItemType Directory -Force $PcDir | Out-Null
    Move-PcSettings $main
    Move-PcRecords $main
}

# The settings of a project on this PC (docs/QUEUE.md, Settings) as one object: its own file (the main checkout's
# `.queue/settings.json`) with the PC's keys from the PC's file. Read before every decision and run, so a change
# applies from the next. $null when neither file is there. PC keys that the project's file holds move to the PC's
# file first.
function Read-ProjectSettings([string] $main) {
    $file = Join-Path $main '.queue/settings.json'
    $own = Read-JsonFile $file
    if (Test-PcKeys $own) {
        Move-PcSettings $main
        $own = Read-JsonFile $file
    }
    $pc = Read-PcSettings
    $shared = @($pc.PSObject.Properties | Where-Object { $PcKeys -contains $_.Name })
    if (-not $own) {
        if (-not $shared.Count) {
            return $null
        }
        $own = [pscustomobject]@{}
    }
    foreach ($property in $shared) {
        Set-JsonProperty $own $property.Name $property.Value
    }
    return $own
}

# Saves the settings of a project: the PC keys into the PC's file, every other key into the project's own. The caller
# holds the 'Settings' lock from its read to this save, so a save of another project's page changes nothing under it.
function Save-ProjectSettings([string] $main, $settings) {
    $pc = [pscustomobject]@{}
    $own = [pscustomobject]@{}
    foreach ($property in $settings.PSObject.Properties) {
        Set-JsonProperty $(if ($PcKeys -contains $property.Name) { $pc } else { $own }) $property.Name $property.Value
    }
    Save-JsonFile (Join-Path $PcDir 'settings.json') $pc
    Save-JsonFile (Join-Path $main '.queue/settings.json') $own
}
