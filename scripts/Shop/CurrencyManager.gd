extends Node
##
## CurrencyManager.gd — 本机玩家的商城货币入口
## Autoload 名: CurrencyManager
##
## 两种货币:
##   credits — 对局/任务赚取, 可在商城直接购买
##   premium — Steam 充值获得, 用于高级箱与限时礼包
##
## 本类不存余额, 每次直接读后端。之前这里有一份 _cache, 而后端才是真源:
## 任何绕过本类直接写后端的路径(比如 ShopProfile 代扣)都会让缓存悄悄过期,
## 表现为"界面显示 5000、实际扣款按 6234 算"这类极难复现的账目错位。
## 读一次字典的成本可以忽略, 少一处真源更值。
##
## 远端玩家的余额不在本单例的职责内 —— 走 ShopProfile(见 ShopManager.profile_for)。
##

const CREDITS := "credits"
const PREMIUM := "premium"


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS


func is_ready() -> bool:
	var b := _backend()
	return b != null and b.is_available()


## 余额唯一真源在后端, 这里只是取名接口
func get_balance(currency_type: String) -> int:
	var b := _backend()
	return 0 if b == null else b.get_currency_balance(currency_type)


func has_enough(currency_type: String, amount: int) -> bool:
	return get_balance(currency_type) >= amount


## 扣款。余额不足返回 false, 且不产生部分扣除。
func spend(currency_type: String, amount: int) -> bool:
	if amount < 0:
		return false
	if amount == 0:
		return true
	var b := _backend()
	if b == null or not has_enough(currency_type, amount):
		return false
	return _write(b, currency_type, get_balance(currency_type) - amount)


## 入账(胜场奖励、开箱返还、充值到账)
func earn(currency_type: String, amount: int) -> int:
	if amount <= 0:
		return get_balance(currency_type)
	var b := _backend()
	if b == null:
		return get_balance(currency_type)
	_write(b, currency_type, get_balance(currency_type) + amount)
	return get_balance(currency_type)


## 退款: 购买失败时把已扣的加回来
func refund(currency_type: String, amount: int) -> void:
	if amount > 0:
		earn(currency_type, amount)


## 直接设定余额。只用于读档对齐与开发调试;
## 正常出入账走 earn/spend, 否则绕掉了下限保护与信号。
func set_currency(currency_type: String, amount: int) -> bool:
	var b := _backend()
	return b != null and _write(b, currency_type, amount)


## 后端被换掉时(测试隔离、Steam 就绪)调用, 让界面立刻反映新余额
func resync() -> void:
	for c in [CREDITS, PREMIUM]:
		EventBus.currency_changed.emit(c, get_balance(c))


func _write(b: IInventoryBackend, currency_type: String, amount: int) -> bool:
	if not b.set_currency_balance(currency_type, amount):
		return false
	EventBus.currency_changed.emit(currency_type, b.get_currency_balance(currency_type))
	return true


func _backend() -> IInventoryBackend:
	return InventoryService.get_backend()
