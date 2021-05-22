### Generate contract input

Use the `l2gen` tool to generate contract inputs from transition proto list

#### Usage examples

`./l2gen -f data/example.json > data/example.txt`: generate input to commit block and dispute transition.

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
