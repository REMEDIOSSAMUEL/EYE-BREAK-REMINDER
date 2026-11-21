param(
  [Parameter(Mandatory=$true)][ValidateSet('Inspect','Add','Remove')][string]$Operation,
  [Parameter(Mandatory=$true)][string]$Thumbprint,
  [string]$CertificatePath,
  [string]$ExpectedCertificateBase64,
  [Parameter(Mandatory=$true)][string]$ResultPath
)
$ErrorActionPreference='Stop'
$store=$null
$certificate=$null
try {
  # The production acceptance script already requires an isolated runner
  # administrator token for exact hosts-file routing. Use that runner's
  # machine root store: the hosted service-profile CurrentUser root-store Add
  # operation can hang even though the child process is correctly bounded.
  $store=[Security.Cryptography.X509Certificates.X509Store]::new([Security.Cryptography.X509Certificates.StoreName]::Root,[Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
  $storeOpenFlags=if($Operation-eq'Inspect'){[Security.Cryptography.X509Certificates.OpenFlags]::ReadOnly}else{[Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite}
  $store.Open($storeOpenFlags)
  $matches=$store.Certificates.Find([Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,$Thumbprint,$false)
  switch($Operation) {
    'Inspect' {
      if($matches.Count-gt1){throw 'The requested thumbprint occurs more than once in the isolated runner machine root store.'}
      $result=[pscustomobject]@{Success=$true;Operation=$Operation;Thumbprint=$Thumbprint;Present=($matches.Count-eq1);RawDataBase64=$(if($matches.Count-eq1){[Convert]::ToBase64String($matches[0].RawData)}else{$null});Removed=$false}
    }
    'Add' {
      if($matches.Count-ne0){throw 'The disposable runner already trusts this generated test certificate; refusing to replace an existing root.'}
      if(-not$CertificatePath-or-not(Test-Path -LiteralPath $CertificatePath -PathType Leaf)){throw 'The certificate file for the test-only root import is missing.'}
      $certificate=[Security.Cryptography.X509Certificates.X509Certificate2]::new([IO.File]::ReadAllBytes($CertificatePath))
      if($certificate.Thumbprint-cne$Thumbprint){throw 'The temporary root certificate bytes do not match their recorded thumbprint.'}
      $store.Add($certificate)
      $matches=$store.Certificates.Find([Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,$Thumbprint,$false)
      if($matches.Count-ne1-or[Convert]::ToBase64String($matches[0].RawData)-cne[Convert]::ToBase64String($certificate.RawData)){throw 'The generated test root was not added byte-for-byte to the isolated runner machine root store.'}
      $result=[pscustomobject]@{Success=$true;Operation=$Operation;Thumbprint=$Thumbprint;Present=$true;RawDataBase64=[Convert]::ToBase64String($matches[0].RawData);Removed=$false}
    }
    'Remove' {
      if(-not$ExpectedCertificateBase64){throw 'Exact DER bytes are required before removing the test-only root.'}
      if($matches.Count-eq0){$result=[pscustomobject]@{Success=$true;Operation=$Operation;Thumbprint=$Thumbprint;Present=$false;RawDataBase64=$null;Removed=$false};break}
      $expected=[Convert]::FromBase64String($ExpectedCertificateBase64)
      if($matches.Count-ne1-or[Convert]::ToBase64String($matches[0].RawData)-cne[Convert]::ToBase64String($expected)){throw 'The machine root-store certificate does not exactly match the generated disposable test root; refusing removal.'}
      $store.Remove($matches[0])
      $remaining=$store.Certificates.Find([Security.Cryptography.X509Certificates.X509FindType]::FindByThumbprint,$Thumbprint,$false)
      if($remaining.Count-ne0){throw 'The disposable test root remains in the isolated runner machine root store after cleanup.'}
      $result=[pscustomobject]@{Success=$true;Operation=$Operation;Thumbprint=$Thumbprint;Present=$false;RawDataBase64=$null;Removed=$true}
    }
  }
  $result | ConvertTo-Json -Compress -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding utf8NoBOM
} catch {
  [pscustomobject]@{Success=$false;Operation=$Operation;Thumbprint=$Thumbprint;Present=$null;RawDataBase64=$null;Removed=$false;Error=$_.Exception.ToString()} | ConvertTo-Json -Compress -Depth 5 | Set-Content -LiteralPath $ResultPath -Encoding utf8NoBOM
  exit 1
} finally {
  if($certificate){$certificate.Dispose()}
  if($store){$store.Close();$store.Dispose()}
}
