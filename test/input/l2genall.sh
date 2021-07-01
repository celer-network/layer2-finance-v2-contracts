#!/bin/bash

prefix=$1
files=$(ls ./data/$prefix*.json)
for eachfile in $files; do
  out=${eachfile/json/txt}
  echo $eachfile '>' $out
  ./l2gen -f $eachfile > $out
  echo
done