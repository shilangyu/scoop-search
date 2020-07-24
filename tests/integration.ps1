go build .

$terms = "fl"

foreach ($term in $terms) {
	$s1 = (./scoop-search.exe $term)
	$s2 = scoop.ps1 search $term *>&1

	if ($s1 -ne $s2) {
		echo "term '$term' failed: "
		$s1 > .\tests\s1.out
		$s2 > .\tests\s2.out
		git diff --no-index .\tests\s1.out .\tests\s2.out
	}

}
