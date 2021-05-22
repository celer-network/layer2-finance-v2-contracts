### Generate contract input

Use the `l2gen` tool to generate contract inputs from transition proto list

#### Usage examples

`./l2gen -f data/example.json > data/example.txt`: generate input to commit block and dispute transition.

#### Configs

```
{AssetId: 1, TestCELR}
{AssetId: 2, TestDAI}
{AssetId: 2, TestWETH}

{StrategyId: 1, AssetId: 2}
{StrategyId: 2, AssetId: 2}
{StrategyId: 3, AssetId: 3}`
```

#### Transition flags

Use the followings flag to mark transition for testing:

- 1: generate dispute data
- 2: generate invalid root and dispute data
- 3: generate invalid signature and dispute data
- 4: generate invalid account id and dispute data
- 99: last transition of a block
