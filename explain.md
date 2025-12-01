# Sorted Set タイムスタンプ機能の変更解説

この変更は、Redis の Sorted Set にタイムスタンプ機能を追加するものです。同じスコアを持つ要素間の順序を、タイムスタンプによって決定できるようになります。

---

## 1. `src/server.h` - データ構造の変更

### zskiplistNode 構造体への timestamp フィールド追加

```c
typedef struct zskiplistNode {
    sds ele;
    double score;
    long long timestamp;  /* Milliseconds since Unix epoch for tie-breaking */
    struct zskiplistNode *backward;
    // ...
} zskiplistNode;
```

**解説**: スキップリストの各ノードに `timestamp` フィールドを追加。ミリ秒単位の Unix エポック時間を保持し、同じスコアを持つ要素の順序決定に使用します。

### 関数シグネチャの変更

```c
zskiplistNode *zslInsert(zskiplist *zsl, double score, long long timestamp, sds ele);
zskiplistNode *zslFind(zskiplist *zsl, double score, sds ele);
zskiplistNode *zslUpdateScore(zskiplist *zsl, double curscore, long long curtimestamp, sds ele, double newscore, long long newtimestamp);
unsigned char *zzlInsert(unsigned char *zl, sds ele, double score, long long timestamp);
long long zzlGetTimestamp(unsigned char *zl, unsigned char *sptr);
int zsetAdd(robj *zobj, double score, long long timestamp, sds ele, int in_flags, int *out_flags, double *newscore);
void ztimestampCommand(client *c);
```

**解説**: 主要な関数に `timestamp` パラメータを追加。新しいコマンド `ZTIMESTAMP` 用の関数も宣言されています。

---

## 2. `src/rdb.h` - RDB 形式の新タイプ定義

```c
#define RDB_TYPE_ZSET_3 26                    /* ZSET version 3 with timestamps stored. */
#define RDB_TYPE_ZSET_LISTPACK_2 27           /* ZSET listpack version 2 with timestamps. */
#define rdbIsObjectType(t) (((t) >= 0 && (t) <= 7) || ((t) >= 9 && (t) <= 27))
```

**解説**: タイムスタンプを保存するための新しい RDB タイプを追加。
- `RDB_TYPE_ZSET_3`: スキップリストエンコーディング用（タイムスタンプ付き）
- `RDB_TYPE_ZSET_LISTPACK_2`: リストパックエンコーディング用（タイムスタンプ付き）

---

## 3. `src/rdb.c` - 永続化の実装

### 保存時のタイプ変更

```c
case OBJ_ZSET:
    if (o->encoding == OBJ_ENCODING_LISTPACK)
        return rdbSaveType(rdb,RDB_TYPE_ZSET_LISTPACK_2);  // 旧: RDB_TYPE_ZSET_LISTPACK
    else if (o->encoding == OBJ_ENCODING_SKIPLIST)
        return rdbSaveType(rdb,RDB_TYPE_ZSET_3);           // 旧: RDB_TYPE_ZSET_2
```

**解説**: Sorted Set を保存する際に、新しいタイムスタンプ付きの RDB タイプを使用するように変更。

### スキップリスト保存時のタイムスタンプ保存

```c
if ((n = rdbSaveBinaryDoubleValue(rdb,zn->score)) == -1)
    return -1;
nwritten += n;
/* Save timestamp for RDB_TYPE_ZSET_3 */
if ((n = rdbSaveLen(rdb,(uint64_t)zn->timestamp)) == -1)
    return -1;
nwritten += n;
```

**解説**: スコアの後にタイムスタンプも保存するように追加。

### 読み込み時のタイムスタンプ復元

```c
/* Load timestamp for RDB_TYPE_ZSET_3 */
if (rdbtype == RDB_TYPE_ZSET_3) {
    uint64_t ts;
    if ((ts = rdbLoadLen(rdb,NULL)) == RDB_LENERR) {
        decrRefCount(o);
        sdsfree(sdsele);
        return NULL;
    }
    timestamp = (long long)ts;
}
```

**解説**: 新しい RDB タイプの場合はタイムスタンプを読み込み、古いタイプの場合は 0 をデフォルト値として使用（後方互換性）。

---

## 4. `src/t_zset.c` - Sorted Set のコア実装

### zslCreateNode - ノード作成時のタイムスタンプ設定

```c
zskiplistNode *zslCreateNode(zskiplist *zsl, int level, double score, long long timestamp, sds ele) {
    // ...
    zn->score = score;
    zn->timestamp = timestamp;  // 新規追加
    zn->ele = ele;
    // ...
}
```

**解説**: スキップリストノード作成時にタイムスタンプを設定。

### zslInsert - 挿入時の順序決定ロジック変更

```c
while (x->level[i].forward &&
        (x->level[i].forward->score < score ||
            (x->level[i].forward->score == score &&
             (x->level[i].forward->timestamp < timestamp ||
                (x->level[i].forward->timestamp == timestamp &&
                 sdscmp(x->level[i].forward->ele,ele) < 0)))))
```

**解説**: 挿入位置を決定する際の比較ロジックを変更。順序は以下の優先度で決定：
1. スコア（昇順）
2. タイムスタンプ（昇順）- 同スコアの場合
3. 要素名（辞書順）- 同スコア・同タイムスタンプの場合

### zslUpdateScore - スコア更新時のタイムスタンプ処理

```c
zskiplistNode *zslUpdateScore(zskiplist *zsl, double curscore, long long curtimestamp, sds ele, double newscore, long long newtimestamp) {
    // ...
    /* If newtimestamp is -1, preserve the original timestamp */
    long long final_timestamp = (newtimestamp == -1) ? x->timestamp : newtimestamp;
    // ...
}
```

**解説**: `newtimestamp` が -1 の場合は既存のタイムスタンプを保持。これにより、モジュール API などでタイムスタンプを明示しない場合の動作を制御。

### zslFind - ノード検索関数（新規追加）

```c
zskiplistNode *zslFind(zskiplist *zsl, double score, sds ele) {
    // スコアと要素名でノードを検索して返す
}
```

**解説**: 指定したスコアと要素名に一致するノードを検索する新しいユーティリティ関数。

### zzlGetTimestamp - リストパックからのタイムスタンプ取得（新規追加）

```c
long long zzlGetTimestamp(unsigned char *zl, unsigned char *sptr) {
    // スコアポインタの次のエントリからタイムスタンプを取得
}
```

**解説**: リストパック形式の Sorted Set からタイムスタンプを取得する関数。

### zzlLength - 長さ計算の変更

```c
unsigned int zzlLength(unsigned char *zl) {
    return lpLength(zl)/3;  /* Each entry has element, score, timestamp */
}
```

**解説**: リストパックの各エントリが (要素, スコア, タイムスタンプ) の 3 つで構成されるように変更（旧: 2 つ）。

### zzlNext / zzlPrev - イテレーション処理の変更

```c
void zzlNext(unsigned char *zl, unsigned char **eptr, unsigned char **sptr) {
    /* Skip timestamp to get to next element */
    _tptr = lpNext(zl,*sptr);  /* timestamp entry */
    if (_tptr != NULL) {
        _eptr = lpNext(zl,_tptr);  /* next element entry */
        // ...
    }
}
```

**解説**: リストパック内を移動する際に、タイムスタンプエントリをスキップするように変更。

### zzlInsert - リストパックへの挿入

```c
unsigned char *zzlInsert(unsigned char *zl, sds ele, double score, long long timestamp) {
    // 要素、スコア、タイムスタンプの順で挿入
}
```

**解説**: 要素挿入時にタイムスタンプも一緒に保存。

### zsetAdd - メインの追加関数

```c
int zsetAdd(robj *zobj, double score, long long timestamp, sds ele, int in_flags, int *out_flags, double *newscore) {
    // timestamp が -1 の場合: 更新時は既存値を保持、新規時は現在時刻を使用
}
```

**解説**: Sorted Set への要素追加の中心的な関数。タイムスタンプの自動設定ロジックを含む。

### ztimestampCommand - 新コマンド ZTIMESTAMP

```c
void ztimestampCommand(client *c) {
    // ZTIMESTAMP key member
    // 指定したメンバーのタイムスタンプを返す
}
```

**解説**: 要素のタイムスタンプを取得する新しいコマンドの実装。

---

## 5. `src/geo.c` - GEO コマンドの対応

```c
/* GEO commands: use 0 as timestamp */
znode = zslInsert(zs->zsl,score,0,gp->member);
```

**解説**: GEO コマンドではタイムスタンプ機能を使用しないため、常に 0 を渡す。

---

## 6. `src/module.c` - モジュール API の対応

```c
/* Module API: use -1 timestamp to preserve existing or use 0 for new */
if (zsetAdd(key->kv,score,-1,ele->ptr,in_flags,&out_flags,NULL) == 0) {
```

**解説**: モジュール API 経由での操作では、タイムスタンプを -1 にして既存値を保持するか、新規追加時は内部で適切な値が設定されるようにする。

---

## 7. `src/redis-check-rdb.c` - RDB チェックツールの対応

```c
char *rdb_type_string[] = {
    // ...
    "zset-v3",
    "zset-listpack-v2",
};
```

**解説**: RDB ファイルのダンプ/チェック時に新しいタイプ名を表示するための文字列を追加。

---

## まとめ

この変更により、以下の機能が実現されます：

1. **同スコア要素の順序制御**: 同じスコアを持つ要素は、タイムスタンプ（挿入/更新時刻）順に並ぶ
2. **ZTIMESTAMP コマンド**: 要素のタイムスタンプを取得可能
3. **後方互換性**: 古い RDB ファイルは引き続き読み込み可能（タイムスタンプは 0 になる）
4. **既存機能との統合**: GEO やモジュール API でも動作

データ構造の変更:
- スキップリスト: 各ノードに `timestamp` フィールドを追加
- リストパック: 各エントリを (要素, スコア) から (要素, スコア, タイムスタンプ) に拡張
