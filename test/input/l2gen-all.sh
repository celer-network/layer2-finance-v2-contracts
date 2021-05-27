files=$(ls ./data/*.json)
for eachfile in $files; do
  out=${eachfile/json/txt}
  echo $eachfile
  ./l2gen -f $eachfile > $out
  echo
done