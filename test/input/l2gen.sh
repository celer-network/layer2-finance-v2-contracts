#!/bin/bash

file=$1
out=${file/json/txt}
echo $file '>' $out
./l2gen -f $file > $out