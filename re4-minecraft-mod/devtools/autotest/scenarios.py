"""Scenarios run against the real Minecraft client with a fake RE4 (fake_re4.FakeRE4). Each returns
{"name", "passed" (True/False, or None when skipped), "details"}."""
import hashlib
import math
import os
import re
import struct
import time


def result(name, passed, **details):
    return {"name": name, "passed": passed, "details": details}


def run_commands(re4, cmds):
    for c in cmds:
        done = re4.command(c)
        while time.time() < done:
            re4.step()


def ensure_alive(re4):
    if re4.bridge().get("dead"):
        done = re4.respawn()
        while time.time() < done:
            re4.step()
        re4.run_for(2.0)


def chat_value(lines, pattern):
    for line in reversed(lines):
        m = re.search(pattern, line)
        if m:
            return m
    return None


def gold_pixels(picture):
    data, w, h = picture
    xs, ys = [], []
    for y in range(0, h - 60, 2):
        row = y * w * 4
        for x in range(0, w, 2):
            r, g, b, a = data[row + x * 4: row + x * 4 + 4]
            if a > 200 and r > 110 and r > 1.5 * b and g > 1.2 * b and abs(r - g) < 90:
                xs.append(x)
                ys.append(y)
    return xs, ys


def opaque_pixels(picture, box):
    data, w, h = picture
    x0, y0, x1, y1 = box
    n = 0
    for y in range(max(0, y0), min(h, y1), 2):
        row = y * w * 4
        for x in range(max(0, x0), min(w, x1), 2):
            if data[row + x * 4 + 3] > 200:
                n += 1
    return n


def drawn_pixels(picture, box, min_alpha=30):
    """Pixels in the box Minecraft drew anything on (see-through stained glass included)."""
    data, w, h = picture
    x0, y0, x1, y1 = box
    n = 0
    for y in range(max(0, y0), min(h, y1)):
        row = y * w * 4
        for x in range(max(0, x0), min(w, x1)):
            if data[row + x * 4 + 3] > min_alpha:
                n += 1
    return n


def native_parts(re4):
    """The parts in minecraft_native_poses.json, each as its 12 fields."""
    poses = re4.read_json("minecraft_native_poses.json") or {}
    return [p.split(",") for p in (poses.get("parts") or "").split(";") if p]


def block_id(x, y, z):
    """Re4Native.blockId: the number a built block goes by in the poses (from BlockPos.asLong)."""
    packed = ((x & 0x3FFFFFF) << 38) | (y & 0xFFF) | ((z & 0x3FFFFFF) << 12)
    return -1 - (packed & 0x7FFFFFFFFFFFFFFF)


def block_box(picture, cam, yaw, fov, block, grow=2):
    """Screen box around a whole block (all 8 corners) seen from a level camera turned by yaw, a little enlarged."""
    _, w, h = picture
    tan_v = math.tan(math.radians(fov / 2))
    tan_h = tan_v * w / h
    y = math.radians(yaw)
    forward, right = (-math.sin(y), math.cos(y)), (-math.cos(y), -math.sin(y))   # (x, z); Minecraft's yaw
    xs, ys = [], []
    for cx in (0, 1):
        for cy in (0, 1):
            for cz in (0, 1):
                dx, dy, dz = block[0] + cx - cam[0], block[1] + cy - cam[1], block[2] + cz - cam[2]
                depth = dx * forward[0] + dz * forward[1]
                xs.append((1 + (dx * right[0] + dz * right[1]) / (depth * tan_h)) / 2 * w)
                ys.append((1 - dy / (depth * tan_v)) / 2 * h)
    return int(min(xs)) - grow, int(min(ys)) - grow, int(max(xs)) + grow, int(max(ys)) + grow


# ---------------------------------------------------------------------------

def lockstep_camera(re4, mc):
    """Minecraft draws from RE4's camera: a block lands where RE4's camera projection says it should."""
    ensure_alive(re4)
    mc.mark()
    re4.yaw, re4.pitch = 0.0, 0.0
    run_commands(re4, ["/setblock ~2 ~ ~4 air", "/setblock ~2 ~ ~4 gold_block"])
    re4.matched = re4.tested = 0
    re4.run_for(2.0)
    m = chat_value(mc.chat_since(), r"Changed the block at (-?\d+), (-?\d+), (-?\d+)")
    pic = re4.overlay_picture()
    if m is None or pic is None:
        return result("lockstep_camera", False, problem="block not placed or no picture", chat=mc.chat_since()[-3:])
    bx, by, bz = (int(v) for v in m.groups())
    pos = re4.bridge().get("pos") or {}
    cam = (pos.get("x", 0), pos.get("y", 0) + 1.62, pos.get("z", 0))
    _, w, h = pic
    cx, cy, cz = bx + 0.5 - cam[0], by + 0.5 - cam[1], bz - cam[2]
    tan_v = math.tan(math.radians(re4.fov / 2))
    tan_h = tan_v * w / h
    sx = (1 + (-cx) / (cz * tan_h)) / 2 * w
    sy = (1 - cy / (cz * tan_v)) / 2 * h
    xs, ys = gold_pixels(pic)
    if not xs:
        return result("lockstep_camera", False, problem="block not visible", predicted=(round(sx), round(sy)))
    inside = min(xs) - 6 <= sx <= max(xs) + 6 and min(ys) - 6 <= sy <= max(ys) + 6
    rate = re4.matched / max(1, re4.tested)
    run_commands(re4, ["/setblock ~2 ~ ~4 air"])
    return result("lockstep_camera", inside and rate >= 0.5, predicted=(round(sx), round(sy)),
                  block_box=(min(xs), min(ys), max(xs), max(ys)), lockstep_match_rate=round(rate, 2))


def golem_fight(re4, mc):
    """An iron golem fights the RE4 enemy's stand-in: RE4 gets the damage and the fight, the golem gets hit back."""
    ensure_alive(re4)
    run_commands(re4, ["/gamemode creative", "/kill @e[type=iron_golem]", "/summon iron_golem ~4 ~ ~-1"])
    before = (re4.bridge().get("enemy_damage") or {}).get("123456789", 0.0)
    engaged_seen = [False]

    def watch(r):
        if "123456789," in (r.bridge().get("engaged") or ""):
            engaged_seen[0] = True
    re4.run_for(14.0, every=watch)
    after = (re4.bridge().get("enemy_damage") or {}).get("123456789", 0.0)
    mc.mark()
    run_commands(re4, ["/data get entity @e[type=iron_golem,sort=nearest,limit=1] Health"])
    re4.run_for(1.0)
    m = chat_value(mc.chat_since(), r"has the following entity data: ([\d.]+)f")
    health = float(m.group(1)) if m else None
    run_commands(re4, ["/kill @e[type=iron_golem]"])
    ok = after > before and engaged_seen[0] and health is not None and health < 100.0
    return result("golem_fight", ok, damage_to_enemy=round(after - before, 1), fight_sent_to_re4=engaged_seen[0],
                  golem_health_after=health)


def native_handoff(re4, mc):
    """Real RE4 mobs: Minecraft exports the golem's parts, sends their poses, and stops drawing what RE4 shows."""
    ensure_alive(re4)
    mc.mark()
    # (the test world is Peaceful: a passive mob with scaled parts, a baby pig, stands in for the scaled ones)
    run_commands(re4, ["/kill @e[type=iron_golem]", "/kill @e[type=pig]", "/summon iron_golem ~0.5 ~ ~3 {NoAI:1b}",
                       "/summon pig ~2.5 ~ ~3 {NoAI:1b,Age:-24000,Rotation:[70f,0f]}"])
    re4.native_status = {"enabled": True, "acked": [], "session": None}
    re4.run_for(8.0)
    assets = re4.read_json("minecraft_native_assets.json")
    if not assets or not assets.get("exports"):
        log = mc.log_since()
        guarded = "not built yet" in log or "could not write the RE4 model" in log
        re4.native_status = {"enabled": False, "acked": [], "session": None}
        re4.run_for(1.0)
        run_commands(re4, ["/kill @e[type=iron_golem]"])
        return result("native_handoff", None if guarded else False,
                      problem="RE4 file writers not in yet (export refused)" if guarded else "no exports")
    pic_before = re4.overlay_picture()
    poses = re4.read_json("minecraft_native_poses.json") or {}
    parts = [p for p in (poses.get("parts") or "").split(";") if p]
    # every rotation sent is a unit quaternion, also for the baby pig's scaled parts
    norms = []
    for p in parts:
        v = p.split(",")
        if len(v) == 12:
            norms.append(math.sqrt(sum(float(x) ** 2 for x in v[5:9])))
    worst_norm_error = max((abs(n - 1.0) for n in norms), default=1.0)
    entities = len({p.split(",")[0] for p in parts})
    re4.native_status = {"enabled": True, "acked": [int(k) for k in assets["exports"]], "session": assets.get("session")}
    re4.run_for(3.0)
    pic_after = re4.overlay_picture()
    w, h = pic_before[1], pic_before[2]
    box = (w // 4, 0, 3 * w // 4, h - 100)
    before_px, after_px = opaque_pixels(pic_before, box), opaque_pixels(pic_after, box)
    re4.native_status = {"enabled": False, "acked": [], "session": None}
    re4.run_for(1.0)
    run_commands(re4, ["/kill @e[type=iron_golem]", "/kill @e[type=pig]"])
    ok = (len(assets["exports"]) >= 6 and len(parts) >= 6 and after_px < 0.25 * max(1, before_px)
          and entities >= 2 and worst_norm_error < 1e-3)
    return result("native_handoff", ok, exports=len(assets["exports"]), parts_in_poses=len(parts), entities=entities,
                  worst_quaternion_norm_error=round(worst_norm_error, 6),
                  overlay_pixels_before=before_px, overlay_pixels_after=after_px)


# The blocks native_blocks builds (name, whether RE4 is to show it, where: sideways and up from the player).
# Biome-coloured leaves and see-through stained glass stay Minecraft's; glass is a cut-out block, so it goes to
# RE4; the crafting table has four textures (top, front, side, planks below). Leaves kept from decaying.
TEST_BLOCKS = [("stone", True, -6, 2), ("oak_planks", True, -4, 2), ("cobblestone", True, -2, 2), ("glass", True, 2, 2),
               ("oak_leaves[persistent=true]", False, 4, 2), ("white_stained_glass", False, 6, 2),
               ("crafting_table", True, 0, 3)]


def tex_size(re4, material):
    """Width and height of the colour texture of an exported material ("minecraft/x.mdf2"), from its header."""
    path = os.path.join(re4.D, "..", "..", "natives", "STM", material[:-len(".mdf2")] + ".tex.143221013")
    try:
        with open(path, "rb") as f:
            return struct.unpack_from("<2H", f.read(12), 8)
    except (OSError, struct.error):
        return None


def native_blocks(re4, mc):
    """Real RE4 blocks: plain blocks you built go to RE4 (each kind with its own small texture, under negative
    numbers in the poses) and Minecraft draws the ones RE4 shows into depth only; the others it still draws."""
    ensure_alive(re4)
    # Facing away from the fake level's raised floor (beyond z=204 in RE4), which would hide the blocks; they are
    # off the screen's centre (crosshair) and above the hand
    re4.yaw, re4.pitch = 180.0, 0.0
    re4.run_for(1.0)
    mc.mark()
    run_commands(re4, [f"/setblock ~{dx} ~{dy} ~-9 {name}" for name, _, dx, dy in TEST_BLOCKS])
    re4.run_for(1.0)
    placed = [tuple(int(v) for v in m) for m in
              re.findall(r"Changed the block at (-?\d+), (-?\d+), (-?\d+)", "\n".join(mc.chat_since()))]
    if len(placed) != len(TEST_BLOCKS):
        re4.yaw = 0.0
        return result("native_blocks", False, problem="blocks not placed", chat=mc.chat_since()[-6:])
    blocks = dict(zip([b[0] for b in TEST_BLOCKS], placed))
    native = [b[0] for b in TEST_BLOCKS if b[1]]
    kept = [b[0] for b in TEST_BLOCKS if not b[1]]

    re4.native_status = {"enabled": True, "acked": [], "session": None}
    re4.run_for(6.0)
    assets = re4.read_json("minecraft_native_assets.json") or {}
    exports = assets.get("exports") or {}
    by_id = {int(p[0]): p for p in native_parts(re4) if len(p) == 12}
    sent = {name: by_id.get(block_id(*pos)) for name, pos in blocks.items()}
    pos = re4.bridge().get("pos") or {}
    cam = (pos.get("x", 0), pos.get("y", 0) + 1.62, pos.get("z", 0))
    pic_before = re4.overlay_picture()
    # RE4 shows the blocks Minecraft sent: their exports are acked, Minecraft then draws them into depth only
    re4.native_status = {"enabled": True, "acked": [int(k) for k in exports], "session": assets.get("session")}
    re4.run_for(3.0)
    pic_after = re4.overlay_picture()
    re4.native_status = {"enabled": False, "acked": [], "session": None}
    re4.run_for(1.0)
    lo, hi = [min(p[i] for p in placed) for i in range(3)], [max(p[i] for p in placed) for i in range(3)]
    run_commands(re4, [f"/fill {lo[0]} {lo[1]} {lo[2]} {hi[0]} {hi[1]} {hi[2]} air"])
    re4.yaw = 0.0

    sent_ok = all(sent[n] is not None for n in native) and all(sent[n] is None for n in kept)
    ids = [sent[n][1] for n in native if sent[n] is not None]
    # each kind of block: its own export with a block texture (not a mob's), no rotation, full size
    files_ok = len(set(ids)) == len(native) and all((exports.get(i) or {}).get("material", "").startswith("minecraft/b_") for i in ids)
    pose_ok = all([float(v) for v in sent[n][5:12]] == [0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0] for n in native if sent[n])
    # its own textures side by side, not the whole block atlas: one square cell per texture
    sizes = {n: tex_size(re4, (exports.get(sent[n][1]) or {}).get("material", "x.mdf2")) for n in native if sent[n]}
    cells_ok = (sizes.get("crafting_table") is not None and sizes["crafting_table"][0] == 4 * sizes["crafting_table"][1]
                and all(s is not None and s[0] == s[1] for n, s in sizes.items() if n != "crafting_table"))
    # one block apart in Minecraft, one block apart in RE4
    spacing = None
    if sent["stone"] and sent["glass"]:
        spacing = round(float(sent["glass"][2]) - float(sent["stone"][2]), 4)
    spacing_ok = spacing == blocks["glass"][0] - blocks["stone"][0]
    pixels = {}
    for name in blocks:
        box = block_box(pic_before, cam, 180.0, re4.fov, blocks[name])
        pixels[name] = (drawn_pixels(pic_before, box), drawn_pixels(pic_after, box))
    hidden_ok = all(b > 100 and a <= 0.1 * b + 5 for b, a in (pixels[n] for n in native))
    drawn_ok = all(b > 100 and a >= 0.7 * b for b, a in (pixels[n] for n in kept))
    ok = sent_ok and files_ok and pose_ok and cells_ok and spacing_ok and hidden_ok and drawn_ok
    return result("native_blocks", ok, sent_to_re4={n: sent[n] is not None for n in blocks}, exports=len(exports),
                  block_materials=[(exports.get(i) or {}).get("material") for i in ids], unrotated_full_size=pose_ok,
                  texture_sizes=sizes, re4_spacing=spacing, overlay_pixels_before_after=pixels)


DEFAULT_SKINS = ["alex", "ari", "efe", "kai", "makena", "noor", "steve", "sunny", "zuri"]


def native_player(re4, mc):
    """Your character in third person as real RE4 parts: the player model (drawn see-through, for the skin's
    outer layer) goes to RE4 with its skin as the texture; back in first person its parts are no longer sent."""
    ensure_alive(re4)
    re4.yaw, re4.pitch = 0.0, 0.0

    def to_camera_mode(wanted):
        # RE4's perspective key, one press at a time (0 first person, 1 behind, 2 in front)
        for _ in range(3):
            if (re4.bridge().get("camera") or {}).get("mode") == wanted:
                return True
            re4.input["perspective"] += 1
            re4.run_for(0.8)
        return (re4.bridge().get("camera") or {}).get("mode") == wanted

    third = to_camera_mode(1)
    re4.native_status = {"enabled": True, "acked": [], "session": None}
    re4.run_for(6.0)
    exports = (re4.read_json("minecraft_native_assets.json") or {}).get("exports") or {}
    me = re4.bridge().get("entity_id")
    mine = [p for p in native_parts(re4) if len(p) == 12 and me is not None and int(p[0]) == me]
    skins = {hashlib.sha1(f"minecraft:textures/entity/player/{m}/{n}.png".encode()).hexdigest()[:16]
             for m in ("wide", "slim") for n in DEFAULT_SKINS}

    def texture_hash(export_id):
        m = re.search(r"/t_([0-9a-f]{16})_r\d+\.mdf2$", (exports.get(export_id) or {}).get("material", ""))
        return m.group(1) if m else None
    with_skin = [p for p in mine if texture_hash(p[1]) in skins]
    first = to_camera_mode(0)
    re4.run_for(1.0)
    gone = not any(len(p) == 12 and me is not None and int(p[0]) == me for p in native_parts(re4))
    re4.native_status = {"enabled": False, "acked": [], "session": None}
    re4.run_for(1.0)
    ok = third and len(with_skin) >= 6 and first and gone
    return result("native_player", ok, third_person=third, entity_id=me, parts_sent=len(mine),
                  parts_with_skin_texture=len(with_skin), back_in_first_person=first, parts_gone_in_first_person=gone)


def leon_damage(re4, mc):
    """RE4's hits on Leon cost Minecraft hearts; RE4 killing Leon kills Minecraft's player."""
    ensure_alive(re4)
    run_commands(re4, ["/gamemode survival", "/effect clear @s"])
    re4.input.update({"leon_damage": 0, "leon_max": 1000, "leon_dead": False})
    re4.run_for(2.0)
    start_health = re4.bridge().get("health")
    re4.input["leon_damage"] = 250
    lowest = [start_health]

    def watch(r):
        hh = r.bridge().get("health")
        if hh is not None:
            lowest[0] = min(lowest[0], hh)
    re4.run_for(0.8, every=watch)
    re4.input["leon_dead"] = True
    died = [False]

    def watch_dead(r):
        if r.bridge().get("dead"):
            died[0] = True
    re4.run_for(2.0, every=watch_dead)
    re4.input.update({"leon_damage": 250, "leon_dead": False})
    ensure_alive(re4)
    run_commands(re4, ["/gamemode creative"])
    for k in ("leon_damage", "leon_max", "leon_dead"):
        re4.input.pop(k, None)
    ok = start_health is not None and lowest[0] is not None and lowest[0] <= start_health - 4.0 and died[0]
    return result("leon_damage", ok, health_before=start_health, lowest_after_hit=lowest[0], died_with_leon=died[0])


def re4_stopped(re4, mc):
    """RE4 stops sending: the player is held at the meeting point, then moved safely to the world spawn."""
    ensure_alive(re4)
    run_commands(re4, ["/gamemode survival"])
    re4.run_for(3.0)
    y_before = (re4.bridge().get("pos") or {}).get("y")
    mc.mark()
    re4.send_input = False
    re4.run_for(13.0)
    log = mc.log_since()
    moved = "moved the player from the RE4 meeting point" in log
    dead = "fell from a high place" in log or "hit the ground too hard" in log
    re4.send_input = True
    re4.run_for(8.0)
    y_after = (re4.bridge().get("pos") or {}).get("y")
    run_commands(re4, ["/gamemode creative"])
    ok = moved and not dead and y_after is not None and abs(y_after - 250.0) < 70.0
    return result("re4_stopped", ok, y_before=y_before, moved_to_spawn=moved, died=dead, y_after_reconnect=y_after)


def support_zip(re4, mc):
    """The menu's "Make support zip": Minecraft zips its log and RE4's files, and says where the zip is."""
    import zipfile
    re4.write_json("minecraft_settings.json", {"gameplay": {"flinch": True}})
    re4.run_for(1.0)
    request = int(time.time())
    re4.input["report_request"] = request
    report, deadline = None, time.time() + 20.0
    while time.time() < deadline:
        re4.run_for(0.5)
        r = re4.bridge().get("report") or {}
        if r.get("seq") == request and r.get("busy") is False:
            report = r
            break
    if report is None or not report.get("path"):
        return result("support_zip", False, report=report)
    with zipfile.ZipFile(report["path"]) as z:
        names = z.namelist()
        summary = z.read("summary.txt").decode("utf-8", "replace") if "summary.txt" in names else ""
    # the same request again is not a new one
    re4.run_for(2.0)
    again = (re4.bridge().get("report") or {}).get("path") == report["path"]
    try:
        import os
        os.remove(report["path"])
    except OSError:
        pass
    wanted = ["summary.txt", "minecraft/latest.log", "installed_files.txt", "re4/reframework/data/minecraft_settings.json",
              "re4/reframework/data/minecraft_bridge.json"]
    ok = all(n in names for n in wanted) and "RE4 Bridge mod" in summary and again
    return result("support_zip", ok, entries=len(names), missing=[n for n in wanted if n not in names],
                  same_request_ignored=again, summary=summary.splitlines()[:3])


ALL = [lockstep_camera, golem_fight, native_handoff, native_blocks, native_player, leon_damage, re4_stopped, support_zip]
