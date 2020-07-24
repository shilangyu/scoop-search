go build .

$terms = "fl"

foreach ($term in $terms) {
	$s1 = (./scoop-search.exe $term)
	$s2 = scoop.ps1 search $term *>&1

	if ([string]$s1 -ne [string]$s2) {
		echo "term '$term' failed: "
		$s1 > .\tests\got.out
		$s2 > .\tests\expected.out
		git diff --no-index .\tests\got.out .\tests\expected.out
	}
}
