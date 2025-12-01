# Redis Sorted Set Timestamp Extension

Redis Sorted Setにタイムスタンプ機能を追加したフォーク版です。同じスコアを持つ要素間でタイムスタンプによるtie-breakが可能になります。  

差分 <https://github.com/a-kaibu/redis/compare/2de1e4e348d82dbfc972ab5d8dc917be8e58d0d8...7657cefb42e99a52945ae8f990a65e5923e83f5b>  

## 機能概要

- Sorted Setの各要素に `score` に加えて `timestamp` を持たせることが可能
- 同スコアの要素はタイムスタンプ順にソート
- ソート順序: `score` → `timestamp` → `lexicographic`（従来の辞書順）

## 新規・拡張コマンド

### ZADD (拡張)

```
ZADD key [NX|XX] [GT|LT] [CH] [INCR] [TIMESTAMP milliseconds] score member [score member ...]
```

`TIMESTAMP` オプションで要素にタイムスタンプを付与できます。

**例:**
```redis
# タイムスタンプ付きで要素を追加
ZADD myset TIMESTAMP 1700000000000 1.0 "item1"
ZADD myset TIMESTAMP 1700000001000 1.0 "item2"
ZADD myset TIMESTAMP 1700000002000 1.0 "item3"

# 同スコア(1.0)でもタイムスタンプ順にソートされる
ZRANGE myset 0 -1
# 結果: "item1", "item2", "item3"
```

**注意:**
- `TIMESTAMP` を省略した場合、新規要素は `timestamp=0` で追加
- 既存要素の更新時に `TIMESTAMP` を省略すると、既存のタイムスタンプが保持される

### ZTIMESTAMP (新規)

```
ZTIMESTAMP key member
```

指定したメンバーのタイムスタンプを取得します。

**例:**
```redis
ZADD myset TIMESTAMP 1700000000000 1.0 "item1"
ZTIMESTAMP myset item1
# 結果: 1700000000000
```

**戻り値:**
- 成功時: タイムスタンプ（ミリ秒単位の整数）
- メンバーが存在しない場合: `nil`

## ユースケース

### 1. 同スコアのアイテムを登録順で並べる

```redis
# ランキングで同点の場合、先に達成した人を上位に
ZADD leaderboard TIMESTAMP 1700000000000 100 "player_a"
ZADD leaderboard TIMESTAMP 1700000001000 100 "player_b"  # 1秒後に同点

ZRANGE leaderboard 0 -1
# player_a が先（タイムスタンプが小さい）
```

### 2. タイムラインの実装

```redis
# タイムスタンプをそのままスコアとして使用する代わりに、
# 優先度(score)とタイムスタンプを分けて管理
ZADD timeline TIMESTAMP 1700000000000 1 "normal_post"
ZADD timeline TIMESTAMP 1700000001000 2 "important_post"
ZADD timeline TIMESTAMP 1700000002000 1 "another_normal"

# 優先度でソート、同優先度内はタイムスタンプ順
```

### 3. イベントキューの順序保証

```redis
# 同じ優先度のイベントをFIFO順で処理
ZADD events TIMESTAMP 1700000000000 1 "event_a"
ZADD events TIMESTAMP 1700000001000 1 "event_b"
ZADD events TIMESTAMP 1700000002000 1 "event_c"

# ZPOPMIN で取り出すと timestamp 順
```

## ビルド方法

### Docker を使用

```bash
docker build -t redis-timestamp .
docker run -d -p 6379:6379 redis-timestamp
```

### ローカルビルド

```bash
make
./src/redis-server
```

## 永続化

- **RDB**: 新しいフォーマット (`RDB_TYPE_ZSET_3`, `RDB_TYPE_ZSET_LISTPACK_2`) でタイムスタンプを保存
- **AOF**: コマンドがそのまま記録されるため自動対応
- **後方互換性**: 古いRDBファイルは `timestamp=0` として読み込み

## 技術的な詳細

### データ構造

- **Skiplist エンコーディング**: `zskiplistNode` に `timestamp` フィールドを追加
- **Listpack エンコーディング**: フォーマットを `[element, score, timestamp, ...]` に変更（従来は `[element, score, ...]`）

### ソート比較ロジック

```
1. score で比較
2. score が同じ場合、timestamp で比較
3. 両方同じ場合、element を辞書順で比較
```

## 制限事項

- タイムスタンプは `int64` (ミリ秒単位)
- 負のタイムスタンプは使用不可
- `ZRANGESTORE` などの一部コマンドではタイムスタンプが `0` にリセットされる場合あり

## ライセンス

Redis と同じライセンスに従います。
