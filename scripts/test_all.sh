# Run each test with a new network, so that block numbers won't be affected by each other
# Must be run from the project root directory

set -e

# Hack to disable typechain generation
HARDHAT_CONFIG_FILE="./hardhat.config.ts"
sed -e "/import '@typechain\/hardhat';/d;/typechain: {/,/}/d" "$HARDHAT_CONFIG_FILE" >$HARDHAT_CONFIG_FILE.new
mv "$HARDHAT_CONFIG_FILE" "$HARDHAT_CONFIG_FILE".bak
mv "$HARDHAT_CONFIG_FILE".new "$HARDHAT_CONFIG_FILE"

files=$(ls test/*.spec.ts)
for eachfile in $files; do
   hardhat test $eachfile
done

mv "$HARDHAT_CONFIG_FILE".bak "$HARDHAT_CONFIG_FILE"
