# Run each test with a new chain, so that block numbers won't be affected by each other
yarn compile
files=`ls test/*.spec.ts`
for eachfile in $files
do
   yarn test-one $eachfile
done