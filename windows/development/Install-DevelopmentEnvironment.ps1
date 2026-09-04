#Requires -Version 5.1
<#
.SYNOPSIS
    Installs user-scoped assets for a Windows development environment.

.DESCRIPTION
    Packages and installs the Jesse C# solution template into the current
    user's dotnet new template registry and seeds personal Copilot instructions
    when they do not already exist. After installation, the template works like
    an SDK template and can be invoked from any directory with:

        dotnet new jesse-csharp

    The installation is package-based. It does not retain a dependency on the
    dotFiles checkout path.

.PARAMETER Validate
    Generates, restores, builds, and tests all application variants after
    installing the template.

.PARAMETER WhatIf
    Shows the development asset installation actions without making changes.

.EXAMPLE
    .\Install-DevelopmentEnvironment.ps1
    Installs or refreshes the user-scoped development assets.

.EXAMPLE
    .\Install-DevelopmentEnvironment.ps1 -Validate
    Installs the development assets and validates all generated application variants.

.EXAMPLE
    .\Install-DevelopmentEnvironment.ps1 -WhatIf
    Shows what would be installed.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Validate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TemplatePackageId = 'Jesse.CSharp.Templates'
$LegacyTemplatePackageIds = @('CanonicalProject.Templates')
$TemplateShortName = 'jesse-csharp'
$MinimumSdkVersion = [version]'10.0.400'
$RepositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
$SharedConfigRoot = Join-Path $RepositoryRoot 'config'
$TemplateRoot = Join-Path $SharedConfigRoot 'templates\csharp'
$TemplateProject = Join-Path $TemplateRoot 'Jesse.CSharp.Templates.csproj'
$TemplateConfiguration = Join-Path $TemplateRoot 'content\jesse-csharp\.template.config\template.json'
$CopilotInstructionsSource = Join-Path $SharedConfigRoot 'copilot\copilot-instructions.md'
$CopilotInstructionsRoot = Join-Path $HOME '.copilot'
$CopilotInstructionsTarget = Join-Path $CopilotInstructionsRoot 'copilot-instructions.md'

function Invoke-DotNet {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,

        [Parameter(Mandatory = $true)]
        [string]$FailureMessage
    )

    & dotnet @Arguments

    if ($LASTEXITCODE -ne 0)
    {
        throw "$FailureMessage Exit code: $LASTEXITCODE."
    }
}

function Test-CompatibleSdk {
    $sdkVersions = & dotnet --list-sdks

    if ($LASTEXITCODE -ne 0)
    {
        throw 'Unable to enumerate installed .NET SDKs.'
    }

    foreach ($line in $sdkVersions)
    {
        if ($line -match '^(\d+\.\d+\.\d+)')
        {
            $version = [version]$Matches[1]

            if ($version.Major -eq $MinimumSdkVersion.Major -and $version -ge $MinimumSdkVersion)
            {
                return $true
            }
        }
    }

    return $false
}

function Test-TemplatePackageInstalled {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )

    $installedPackages = & dotnet new uninstall 2>&1

    if ($LASTEXITCODE -ne 0)
    {
        throw 'Unable to enumerate installed dotnet new template packages.'
    }

    $packagePattern = '^\s*' + [regex]::Escape($PackageId) + '\s*$'
    return $null -ne ($installedPackages | Select-String -Pattern $packagePattern)
}

function Test-ApplicationVariants {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ValidationRoot
    )

    foreach ($applicationType in @('class-library', 'console', 'web-api', 'worker'))
    {
        $projectName = 'Bootstrap.' + ($applicationType -replace '-', '')
        $projectRoot = Join-Path $ValidationRoot $applicationType
        $arguments = @(
            'new',
            $TemplateShortName,
            '--name',
            $projectName,
            '--output',
            $projectRoot,
            '--no-update-check'
        )

        if ($applicationType -ne 'console')
        {
            $arguments += @('--apptype', $applicationType)
        }

        Write-Host "Generating $applicationType validation project..." -ForegroundColor Cyan
        Invoke-DotNet `
            -Arguments $arguments `
            -FailureMessage "Failed to generate the $applicationType template variant."

        if ($applicationType -eq 'console')
        {
            $projectFile = Join-Path $projectRoot "src\$projectName\$projectName.csproj"
            $sourceRoot = Join-Path $projectRoot "src\$projectName"
            $entryPointFile = Join-Path $sourceRoot 'EntryPoint.cs'
            $implementationFiles = @(Get-ChildItem -LiteralPath $sourceRoot -Filter '*.cs' -File)

            if (-not (Select-String -LiteralPath $projectFile -SimpleMatch '<OutputType>Exe</OutputType>' -Quiet))
            {
                throw 'The default application type did not produce a console project.'
            }

            if (($implementationFiles.Count -ne 1) -or ($implementationFiles[0].Name -ne 'EntryPoint.cs'))
            {
                throw 'The console application must contain only EntryPoint.cs at its source root.'
            }

            if (-not (Select-String -LiteralPath $entryPointFile -SimpleMatch 'Console.WriteLine("Hello, World!");' -Quiet))
            {
                throw 'The console entry point does not write Hello, World.'
            }

            if (Test-Path -LiteralPath (Join-Path $projectRoot 'tests\GreetingServiceTests.cs'))
            {
                throw 'The console output contains a test for the excluded greeting service.'
            }

            if (-not (Test-Path -LiteralPath (Join-Path $projectRoot 'tests\EntryPointTests.cs') -PathType Leaf))
            {
                throw 'The console output does not contain the entry point test.'
            }
        }

        Push-Location $projectRoot

        try
        {
            Invoke-DotNet -Arguments @('restore') -FailureMessage "Restore failed for $applicationType."
            Invoke-DotNet -Arguments @('build', '--no-restore') -FailureMessage "Build failed for $applicationType."
            Invoke-DotNet -Arguments @('test', '--no-build') -FailureMessage "Tests failed for $applicationType."
        }
        finally
        {
            Pop-Location
        }
    }

    $projectName = '123-sample'
    $projectRoot = Join-Path $ValidationRoot 'leading-digit'

    Write-Host 'Generating leading-digit validation project...' -ForegroundColor Cyan
    Invoke-DotNet `
        -Arguments @(
            'new',
            $TemplateShortName,
            '--name',
            $projectName,
            '--output',
            $projectRoot,
            '--apptype',
            'class-library',
            '--no-update-check'
        ) `
        -FailureMessage 'Failed to generate the leading-digit validation project.'

    $sourceFile = Join-Path $projectRoot 'src\123-sample\GreetingService.cs'

    if (-not (Select-String -LiteralPath $sourceFile -SimpleMatch 'namespace Project123sample;' -Quiet))
    {
        throw 'The leading-digit project name did not produce a C#-safe namespace.'
    }

    Push-Location $projectRoot

    try
    {
        Invoke-DotNet -Arguments @('restore') -FailureMessage 'Restore failed for the leading-digit project.'
        Invoke-DotNet -Arguments @('build', '--no-restore') -FailureMessage 'Build failed for the leading-digit project.'
        Invoke-DotNet -Arguments @('test', '--no-build') -FailureMessage 'Tests failed for the leading-digit project.'
    }
    finally
    {
        Pop-Location
    }
}

if (-not (Get-Command dotnet -ErrorAction SilentlyContinue))
{
    throw '.NET SDK is required. Install .NET SDK 10.0.400 or later before running this bootstrap.'
}

if (-not (Test-Path -LiteralPath $TemplateProject -PathType Leaf))
{
    throw "Template package project not found at '$TemplateProject'."
}

if (-not (Test-Path -LiteralPath $TemplateConfiguration -PathType Leaf))
{
    throw "Template configuration not found at '$TemplateConfiguration'."
}

if (-not (Test-Path -LiteralPath $CopilotInstructionsSource -PathType Leaf))
{
    throw "Copilot instructions not found at '$CopilotInstructionsSource'."
}

if (-not (Test-CompatibleSdk))
{
    throw "The Jesse C# template requires .NET SDK $MinimumSdkVersion or a later .NET 10 SDK."
}

$stagingRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dotfiles-development-' + [guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $stagingRoot 'packages'
$buildRoot = Join-Path $stagingRoot 'artifacts'
$validationRoot = Join-Path $stagingRoot 'validation'

try
{
    $installAction = if (Test-Path -LiteralPath $CopilotInstructionsTarget)
    {
        'Refresh dotnet new template and preserve existing Copilot instructions'
    }
    else
    {
        'Install shared Copilot instructions and dotnet new template'
    }

    if ($PSCmdlet.ShouldProcess('User development environment', $installAction))
    {
        New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null

        Write-Host "Packing $TemplatePackageId..." -ForegroundColor Cyan
        Invoke-DotNet `
            -Arguments @(
                'pack',
                $TemplateProject,
                '--configuration',
                'Release',
                '--artifacts-path',
                $buildRoot,
                '--output',
                $packageRoot,
                '--nologo'
            ) `
            -FailureMessage 'Failed to build the Jesse C# template package.'

        $package = Get-ChildItem -LiteralPath $packageRoot -Filter "$TemplatePackageId.*.nupkg" -File |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1

        if ($null -eq $package)
        {
            throw "The template package '$TemplatePackageId' was not produced."
        }

        foreach ($packageId in @($LegacyTemplatePackageIds) + $TemplatePackageId)
        {
            if (Test-TemplatePackageInstalled -PackageId $packageId)
            {
                Write-Host "Removing the installed $packageId package..." -ForegroundColor Cyan
                Invoke-DotNet `
                    -Arguments @('new', 'uninstall', $packageId) `
                    -FailureMessage "Failed to remove the installed '$packageId' template package."
            }
        }

        Write-Host "Installing $($package.Name)..." -ForegroundColor Cyan
        Invoke-DotNet `
            -Arguments @('new', 'install', $package.FullName) `
            -FailureMessage 'Failed to install the Jesse C# template package.'

        Invoke-DotNet `
            -Arguments @('new', $TemplateShortName, '--help') `
            -FailureMessage "The '$TemplateShortName' template was installed but cannot be resolved."

        if (Test-Path -LiteralPath $CopilotInstructionsTarget)
        {
            Write-Host "Personal Copilot instructions already exist at $CopilotInstructionsTarget. Installation skipped." -ForegroundColor Yellow
        }
        else
        {
            Write-Host "Installing personal Copilot instructions..." -ForegroundColor Cyan
            New-Item -ItemType Directory -Path $CopilotInstructionsRoot -Force | Out-Null
            Copy-Item `
                -LiteralPath $CopilotInstructionsSource `
                -Destination $CopilotInstructionsTarget
        }

        if ($Validate)
        {
            New-Item -ItemType Directory -Path $validationRoot -Force | Out-Null
            Test-ApplicationVariants -ValidationRoot $validationRoot
        }

        Write-Host ""
        Write-Host "Jesse C# template installed successfully." -ForegroundColor Green
        Write-Host "Create a project from any directory with:" -ForegroundColor Green
        Write-Host "  dotnet new jesse-csharp --name <ProjectName>" -ForegroundColor White
        Write-Host "Add --location <path> to select another containing directory." -ForegroundColor White
        Write-Host "Use --apptype for class-library, web-api, or worker projects." -ForegroundColor White
    }
}
finally
{
    if (Test-Path -LiteralPath $stagingRoot)
    {
        Remove-Item -LiteralPath $stagingRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
