file=$1
echo $file
out=${file/json/txt}
./l2gen -f $file > $out