"""Enemies swinging at Minecraft mobs (minecraft_gameplay.lua) and the Attack test that finds how
(minecraft_diagnostics.lua), in the fake REFramework of harness_diag.py.   python3 test_attacks.py"""
import math
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.argv = sys.argv[:1]
import harness_diag as H  # noqa: E402

ATTACK = "SickleSwingFast.SickleSwingFast.AxeContinuousAttack.Timer.attack_1st_com_0355_continuous_two"
IDLE = "Move.Move.ch1c0Move.general_0th_com_0000_idle_loop_verA"
# REFramework pieces the fake doesn't have: SetNodeInfo (a value type) and Quaternion.new(w, x, y, z)
STUBS = '''
local old = sdk.find_type_definition
sdk.find_type_definition = function(name)
    if name == "via.behaviortree.SetNodeInfo" then return { is_value_type = function() return true end } end
    return old(name)
end
ValueType = { new = function(td) return { fake_value = true } end }
Quaternion = { new = function(w, x, y, z) return { w = w, x = x, y = y, z = z } end }
'''
# The enemy's MotionFsm2 knows the attack state and goes into it when asked; its transform records turns
ENEMY = f'''
local st = FAKE.enemy_by_id[1]
local fsm = st.body._m["getComponent(System.Type)"](st.body, {{ type_name = "via.motion.MotionFsm2" }})
SETS = 0
fsm._m["hasNodeFullName(System.String)"] = function(_, n) return n == "{ATTACK}" end
fsm._m["setCurrentNode(System.String, System.UInt32, via.behaviortree.SetNodeInfo)"] = function(_, n, layer, info)
    SETS = SETS + 1; LAYER = layer; st.node = n
end
ROTS = 0
local tr = st.body._m.get_Transform(st.body)
local old_set = tr._m.set_Rotation
tr._m.set_Rotation = function(self, q) ROTS = ROTS + 1; LASTQ = q; if old_set then return old_set(self, q) end end
KEY = tostring(st.ctx:get_address())
'''
fails = 0


def check(name, ok, info=""):
    global fails
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  :: " + str(info)))
    if not ok:
        fails += 1


def swings():
    print("== enemies swing at the mobs fighting them ==")
    w = H.World(setup=STUBS + f'FAKE.files["minecraft_attack.json"] = {{ works = true, nodes = {{ "{ATTACK}" }}, time = "t" }}')
    check("saved attack states loaded", w.ev("MinecraftRE4Attack.works") is True, w.ev("MinecraftRE4Attack.status"))
    w.lua("FAKE.make_enemy({ id = 1, pos = { 0, 0, 3 }, hp = 100 })")
    w.lua(ENEMY)
    w.step(200)   # (gameplay waits for the game to place Leon first)
    w.lua('BRIDGE.engaged = KEY .. ",1.5,1.3,3;"')   # a mob 1.5 m to the enemy's +x
    w.step(4)
    check("enemy swings at the mob in reach", w.ev("SETS") == 1 and w.ev("LAYER") == 0, (w.ev("SETS"), w.ev("LAYER")))
    q = w.ev("LASTQ")
    check("turned to face the mob (+x: yaw 90 degrees)",
          q is not None and abs(q.w - math.sqrt(0.5)) < 1e-3 and abs(q.y - math.sqrt(0.5)) < 1e-3, q and (q.w, q.x, q.y, q.z))
    w.lua(f'FAKE.enemy_by_id[1].node = "{IDLE}"')
    w.step(60)
    check("no second swing within the cooldown", w.ev("SETS") == 1, w.ev("SETS"))
    w.step(100)
    check("swings again after the cooldown", w.ev("SETS") == 2, w.ev("SETS"))
    w.lua('FAKE.enemy_by_id[1].node = "Damage.Wince.small"')
    w.step(200)
    check("no swing while in a damage reaction", w.ev("SETS") == 2, w.ev("SETS"))
    w.lua(f'FAKE.enemy_by_id[1].node = "{IDLE}"; BRIDGE.engaged = KEY .. ",9,1.3,3;"')
    w.step(200)
    check("no swing when the mob is out of reach", w.ev("SETS") == 2, w.ev("SETS"))
    w.lua('MinecraftRE4Control.mode = "re4"; MinecraftRE4Control.reason = "get_IsEventLocked"; BRIDGE.engaged = KEY .. ",1.5,1.3,3;"')
    w.step(200)
    check("no swing during RE4's scenes", w.ev("SETS") == 2, w.ev("SETS"))
    check("no Lua errors", not w.errors(), w.errors()[:2])


def without_test():
    print("== nothing happens before the Attack test found a way ==")
    w = H.World(setup=STUBS)
    w.lua("FAKE.make_enemy({ id = 1, pos = { 0, 0, 3 }, hp = 100 })")
    w.lua(ENEMY)
    w.step(200)
    w.lua('BRIDGE.engaged = KEY .. ",1.5,1.3,3;"')
    w.step(200)
    check("no swing without minecraft_attack.json", w.ev("SETS") == 0 and w.ev("ROTS") == 0, (w.ev("SETS"), w.ev("ROTS")))


def attack_test():
    print("== Attack test (diagnostics) ==")
    w = H.World(setup=STUBS)
    w.lua("FAKE.make_enemy({ id = 1, pos = { 0, 0, 3 }, hp = 100 })")
    w.lua(ENEMY)
    w.lua(f'FAKE.enemy_by_id[1].node = "{ATTACK}"')
    w.step(40)    # the states sampler sees the attack state
    w.lua(f'FAKE.enemy_by_id[1].node = "{IDLE}"')
    w.step(5)
    w.press("Attack test")
    w.step(1)
    w.step(85)
    check("the attack state was asked for, on layer 0", w.ev("SETS") == 1 and w.ev("LAYER") == 0, (w.ev("SETS"), w.ev("LAYER")))
    check("the enemy was turned to the point first", w.ev("ROTS") >= 1, w.ev("ROTS"))
    saved = w.F.files["minecraft_attack.json"]
    check("success saved in minecraft_attack.json", saved is not None and saved.works is True and saved.nodes[1] == ATTACK)
    check("gameplay picked it up at once", w.ev("MinecraftRE4Attack.works") is True, w.ev("MinecraftRE4Attack.status"))
    check("result line", any("enemies now swing at the mobs" in t for t in w.ui()), [t for t in w.ui() if "attack" in t.lower()][:3])
    check("no Lua errors", not w.errors(), w.errors()[:2])


swings()
without_test()
attack_test()
print("FAILS", fails)
sys.exit(1 if fails else 0)
