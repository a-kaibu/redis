# Redis Sorted Sets に Timestamp を追加する実装計画
****
## 概要

Sorted Sets の member に score と timestamp の両方を含め、同スコア時は timestamp で順序を決定する機能を追加する。

## 要件

| 項目 | 内容 |
|------|------|
| **目的** | 同スコア時の順序決定 |
| **ソート順** | score → timestamp → 辞書順 |
| **timestamp形式** | int64 ミリ秒（Unix epoch から） |
| **API方針** | 既存コマンドを拡張 |

---

## 実装ステップ

### Phase 1: データ構造の変更

#### 1.1 `server.h` - zskiplistNode の拡張

```c
typedef struct zskiplistNode {
    sds ele;                 // Element (string)
    double score;            // Numeric score
    int64_t timestamp;       // NEW: ミリ秒単位の timestamp
    struct zskiplistNode *backward;
    struct zskiplistLevel {
        struct zskiplistNode *forward;
        unsigned long span;
    } level[];
} zskiplistNode;
```

#### 1.2 Listpack encoding の更新

- listpack 内のデータ形式を `[element, score, timestamp, element, score, timestamp, ...]` に変更
- 後方互換性のため、古い形式（timestamp なし）も読み込み可能にする

---

### Phase 2: 比較ロジックの変更

#### 2.1 `t_zset.c` - 比較関数の修正

修正対象の関数:
- `zslValueGteMin()` / `zslValueLteMax()`
- `zslInsert()`
- `zslDelete()`
- `zslGetRank()`

比較ロジック:
```
1. score で比較
2. score が同じなら timestamp で比較（昇順）
3. timestamp も同じなら member の辞書順で比較
```

---

### Phase 3: コマンドの拡張

#### 3.1 追加・更新系コマンド

| コマンド | 変更内容 |
|----------|----------|
| **ZADD** | `TIMESTAMP ms` オプション追加 |
| **ZINCRBY** | `TIMESTAMP ms` オプション追加（更新時の timestamp 指定） |

**ZADD 新構文:**
```
ZADD key [NX|XX] [GT|LT] [CH] [INCR] [TIMESTAMP ms] score member [score member ...]
```

**ZINCRBY 新構文:**
```
ZINCRBY key [TIMESTAMP ms] increment member
```

- `TIMESTAMP ms`: 明示的に timestamp を指定
- 省略時: 0（timestamp 無効）または現在時刻を自動設定（要検討）

#### 3.2 取得系コマンド（WITHTIMESTAMPS 対応）

| コマンド | 変更内容 |
|----------|----------|
| **ZRANGE** | `WITHTIMESTAMPS` オプション追加 |
| **ZREVRANGE** | `WITHTIMESTAMPS` オプション追加 |
| **ZRANGEBYSCORE** | `WITHTIMESTAMPS` オプション追加 |
| **ZREVRANGEBYSCORE** | `WITHTIMESTAMPS` オプション追加 |
| **ZRANGEBYLEX** | `WITHTIMESTAMPS` オプション追加 |
| **ZREVRANGEBYLEX** | `WITHTIMESTAMPS` オプション追加 |
| **ZRANDMEMBER** | `WITHTIMESTAMPS` オプション追加 |
| **ZSCAN** | timestamp を含めて返すオプション追加 |

**構文例:**
```
ZRANGE key start stop [BYSCORE|BYLEX] [REV] [LIMIT offset count] [WITHSCORES] [WITHTIMESTAMPS]
ZREVRANGE key start stop [WITHSCORES] [WITHTIMESTAMPS]
ZRANGEBYSCORE key min max [WITHSCORES] [WITHTIMESTAMPS] [LIMIT offset count]
ZREVRANGEBYSCORE key max min [WITHSCORES] [WITHTIMESTAMPS] [LIMIT offset count]
```

#### 3.3 単一要素取得系コマンド

| コマンド | 変更内容 |
|----------|----------|
| **ZSCORE** | そのまま（score のみ返す） |
| **ZMSCORE** | そのまま（score のみ返す） |
| **ZRANK** | `WITHTIMESTAMP` オプション追加 |
| **ZREVRANK** | `WITHTIMESTAMP` オプション追加 |

**新コマンド:**
```
ZTIMESTAMP key member              # member の timestamp を取得
ZMTIMESTAMP key member [member ...]  # 複数 member の timestamp を取得
```

#### 3.4 POP 系コマンド

| コマンド | 変更内容 |
|----------|----------|
| **ZPOPMIN** | `WITHTIMESTAMPS` オプション追加 |
| **ZPOPMAX** | `WITHTIMESTAMPS` オプション追加 |
| **ZMPOP** | `WITHTIMESTAMPS` オプション追加 |
| **BZPOPMIN** | `WITHTIMESTAMPS` オプション追加 |
| **BZPOPMAX** | `WITHTIMESTAMPS` オプション追加 |
| **BZMPOP** | `WITHTIMESTAMPS` オプション追加 |

#### 3.5 集合演算系コマンド

| コマンド | 変更内容 |
|----------|----------|
| **ZUNION** | `WITHTIMESTAMPS` オプション追加、timestamp 集約方法の指定 |
| **ZINTER** | `WITHTIMESTAMPS` オプション追加、timestamp 集約方法の指定 |
| **ZDIFF** | `WITHTIMESTAMPS` オプション追加 |
| **ZUNIONSTORE** | timestamp の集約方法を指定（MIN/MAX/SUM） |
| **ZINTERSTORE** | timestamp の集約方法を指定（MIN/MAX/SUM） |
| **ZDIFFSTORE** | 元の timestamp を保持 |

**timestamp 集約オプション:**
```
ZUNIONSTORE destkey numkeys key [key ...] [WEIGHTS weight [weight ...]] [AGGREGATE SUM|MIN|MAX] [TIMESTAMPAGGREGATE MIN|MAX]
```

#### 3.6 削除系コマンド（変更なし）

| コマンド | 変更内容 |
|----------|----------|
| ZREM | 変更不要 |
| ZREMRANGEBYRANK | 変更不要 |
| ZREMRANGEBYSCORE | 変更不要 |
| ZREMRANGEBYLEX | 変更不要 |

#### 3.7 その他コマンド（変更なし）

| コマンド | 変更内容 |
|----------|----------|
| ZCARD | 変更不要 |
| ZCOUNT | 変更不要 |
| ZLEXCOUNT | 変更不要 |
| ZINTERCARD | 変更不要 |

---

### Phase 4: 永続化対応

#### 4.1 RDB フォーマット

- 新しい RDB type を追加: `RDB_TYPE_ZSET_TIMESTAMP`
- 既存の `RDB_TYPE_ZSET_*` との後方互換性を維持
- RDB バージョン番号の更新が必要

**データ形式:**
```
[member_len][member][score (8 bytes)][timestamp (8 bytes)]
```

#### 4.2 AOF フォーマット

- ZADD コマンドに TIMESTAMP オプションを含めて記録
- 例: `ZADD mykey TIMESTAMP 1701388800000 100 member1`

---

### Phase 5: レプリケーション対応

- マスター → レプリカへの伝播時に timestamp を含める
- AOF 形式で伝播されるため、Phase 4 の実装で自動的に対応

---

### Phase 6: テスト

#### 6.1 ユニットテスト (`tests/unit/type/zset.tcl`)

追加するテストケース:
- 基本的な ZADD with TIMESTAMP
- 同スコア・異なる timestamp でのソート順
- 同スコア・同 timestamp での辞書順ソート
- WITHTIMESTAMPS オプションの動作
- ZTIMESTAMP コマンドの動作
- RDB/AOF の永続化と復元
- encoding 変換（listpack ↔ skiplist）

#### 6.2 統合テスト

- レプリケーションでの timestamp 同期
- クラスタ環境での動作確認

---

## 検討事項

### 後方互換性

| シナリオ | 対応方針 |
|----------|----------|
| 既存データの読み込み | timestamp = 0 として扱う |
| 古い Redis との混在 | 新 RDB type は古い Redis では読めない |
| クライアント互換性 | TIMESTAMP オプションは任意、省略可能 |

### 設計上の決定が必要な項目

1. **TIMESTAMP 省略時のデフォルト値**
   - 0（無効値として扱う）
   - 現在時刻を自動設定

2. **ZINCRBY での timestamp 更新**
   - 更新しない（元の timestamp を保持）
   - 新しい timestamp で上書き

3. **timestamp によるレンジクエリ**
   - `ZRANGEBYTIMESTAMP` コマンドを追加するか？
   - 複合条件（score + timestamp）でのフィルタリング

---

## ファイル変更一覧

### コア実装

| ファイル | 変更内容 |
|----------|----------|
| `src/server.h` | zskiplistNode に timestamp フィールド追加 |
| `src/t_zset.c` | 比較ロジック、全コマンド実装の修正 |

### コマンド定義（JSON）

| ファイル | 変更内容 |
|----------|----------|
| `src/commands/zadd.json` | TIMESTAMP オプション追加 |
| `src/commands/zincrby.json` | TIMESTAMP オプション追加 |
| `src/commands/zrange.json` | WITHTIMESTAMPS オプション追加 |
| `src/commands/zrevrange.json` | WITHTIMESTAMPS オプション追加 |
| `src/commands/zrangebyscore.json` | WITHTIMESTAMPS オプション追加 |
| `src/commands/zrevrangebyscore.json` | WITHTIMESTAMPS オプション追加 |
| `src/commands/zrangebylex.json` | WITHTIMESTAMPS オプション追加 |
| `src/commands/zrevrangebylex.json` | WITHTIMESTAMPS オプション追加 |
| `src/commands/zrank.json` | WITHTIMESTAMP オプション追加 |
| `src/commands/zrevrank.json` | WITHTIMESTAMP オプション追加 |
| `src/commands/zpopmin.json` | WITHTIMESTAMPS オプション追加 |
| `src/commands/zpopmax.json` | WITHTIMESTAMPS オプション追加 |
| `src/commands/zmpop.json` | WITHTIMESTAMPS オプション追加 |
| `src/commands/bzpopmin.json` | WITHTIMESTAMPS オプション追加 |
| `src/commands/bzpopmax.json` | WITHTIMESTAMPS オプション追加 |
| `src/commands/bzmpop.json` | WITHTIMESTAMPS オプション追加 |
| `src/commands/zunion.json` | WITHTIMESTAMPS, TIMESTAMPAGGREGATE 追加 |
| `src/commands/zinter.json` | WITHTIMESTAMPS, TIMESTAMPAGGREGATE 追加 |
| `src/commands/zdiff.json` | WITHTIMESTAMPS オプション追加 |
| `src/commands/zunionstore.json` | TIMESTAMPAGGREGATE オプション追加 |
| `src/commands/zinterstore.json` | TIMESTAMPAGGREGATE オプション追加 |
| `src/commands/zrandmember.json` | WITHTIMESTAMPS オプション追加 |
| `src/commands/zscan.json` | WITHTIMESTAMPS オプション追加 |
| `src/commands/ztimestamp.json` | **新規作成** |
| `src/commands/zmtimestamp.json` | **新規作成** |

### 永続化

| ファイル | 変更内容 |
|----------|----------|
| `src/rdb.c` | 新 RDB type の保存・読み込み |
| `src/rdb.h` | RDB type 定数の追加 |
| `src/aof.c` | AOF 出力に timestamp を含める |

### テスト

| ファイル | 変更内容 |
|----------|----------|
| `tests/unit/type/zset.tcl` | 全コマンドのテストケース追加 |

---

## 実装順序（推奨）

```
1. server.h の構造体変更
2. t_zset.c の skiplist 操作関数を修正
3. t_zset.c の listpack 操作関数を修正
4. ZADD コマンドの拡張
5. ZRANGE 系コマンドの拡張
6. ZTIMESTAMP コマンドの追加
7. RDB 永続化対応
8. AOF 永続化対応
9. テスト作成
10. ドキュメント更新
```

---

## デメリット・トレードオフ

### 1. メモリ使用量の増加

| 項目 | 影響 |
|------|------|
| **skiplist encoding** | 各要素に +8 bytes（int64） |
| **listpack encoding** | 各要素に +1〜9 bytes（可変長整数） |
| **dict のエントリ** | 必要に応じて timestamp も保持する場合、追加のメモリ |

**例**: 100万要素の zset → 約 **+8MB** のメモリ増加（skiplist の場合）

### 2. パフォーマンスへの影響

| 操作 | 影響 |
|------|------|
| **比較処理** | score が同じ場合に追加の比較が発生（通常は軽微） |
| **挿入・削除** | わずかに遅くなる可能性（メモリコピー量増加） |
| **RDB/AOF** | 保存・読み込み時のデータ量増加 |
| **レプリケーション** | 転送データ量の増加 |

### 3. 後方互換性の問題

| 問題 | 詳細 |
|------|------|
| **RDB 非互換** | 新フォーマットの RDB は古い Redis で読めない |
| **クラスタ混在不可** | アップグレード時は全ノード同時更新が必要 |
| **クライアント対応** | 新オプションを使うにはクライアント側の更新が必要 |

### 4. 複雑性の増加

- **コードの複雑化**: 全ての zset 操作で timestamp を考慮する必要
- **テスト範囲の拡大**: 既存テスト + timestamp 関連の組み合わせテスト
- **ドキュメント**: 全コマンドの説明更新が必要
- **バグの可能性**: 変更箇所が多いため、エッジケースでのバグリスク

### 5. 設計上の課題

| 課題 | 詳細 |
|------|------|
| **集合演算の曖昧さ** | ZUNION 等で timestamp をどう集約するか（MIN? MAX? どちらも微妙） |
| **ZINCRBY の挙動** | score 更新時に timestamp も更新すべきか、判断が難しい |
| **クラスタ間の時刻同期** | ノード間で時刻がずれていると、期待通りの順序にならない可能性 |

### 6. 代替案

Redis 本体を改造せずに同様の目的を達成する方法:

```bash
# 代替案1: score に timestamp を埋め込む
# score = actual_score * 10^13 + timestamp_ms
ZADD key 100.1701388800000 member1

# 代替案2: member に timestamp を含める
ZADD key 100 "member1:1701388800000"

# 代替案3: 別の Hash で timestamp を管理
ZADD myset 100 member1
HSET myset:timestamps member1 1701388800000
```

**代替案で十分なら、Redis 本体を改造する必要はない**

### 7. 総合評価

| 観点 | 評価 |
|------|------|
| 実装コスト | **高** - 変更箇所が多い |
| メンテナンスコスト | **中〜高** - Redis アップグレード時に追従が必要 |
| メモリコスト | **中** - 要素数に比例して増加 |
| 性能影響 | **低** - 通常の操作では軽微 |
