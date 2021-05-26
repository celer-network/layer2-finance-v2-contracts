yarn compile
files=`ls test/*.spec.ts`
for eachfile in $files
do
   yarn test-one $eachfile
done