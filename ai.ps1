#Requires -Version 5.1
param(
    [Alias('b')][string]$Backend = 'nv'
)
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
& "$scriptDir\deepantigravity.ps1" -Backend $Backend
