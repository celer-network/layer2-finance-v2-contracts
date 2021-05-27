### Generate contract testing inputs

Use the `l2gen` tool to generate contract inputs from transition proto list

#### Usage examples

Generate input data to commit blocks and dispute transitions:

`./l2gen -f data/example.json > data/example.txt` or `./l2gen.sh data/example.json`

Generate inputs for all tests: `./l2genall.sh`

#### Configs

```
assetId 1: testCELR
assetId 2: testDAI
assetId 3: testWETH

strategyId 1: assetId 2
strategyId 2: assetId 2
strategyId 3: assetId 3
```

#### Transition flags

Use the followings flag to mark transition for testing:

- 1: generate dispute data
- 2: generate invalid root and dispute data
- 3: generate invalid signature and dispute data
- 4: generate invalid account id and dispute data
- 99: last transition of a block
