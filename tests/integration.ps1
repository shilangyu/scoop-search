go build .

# add a bucket that holds manifests in root
scoop bucket add github-gh https://github.com/cli/scoop-gh.git

$terms = "fl", "android", "sudo", "", "azure", "t", "a", "P", "G", "as", "gh"

foreach ($term in $terms) {
	$s1 = (./scoop-search.exe $term)
	$s2 = scoop.ps1 search $term *>&1

	if ([string]$s1 -ne [string]$s2) {
		Write-Output "term '$term' failed:"
		$s1 > .\tests\got.out
		$s2 > .\tests\expected.out
		git diff --no-index .\tests\got.out .\tests\expected.out
		Write-Output ""
	}
}
