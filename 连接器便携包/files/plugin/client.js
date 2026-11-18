// dsh-connector client 侧（浏览器界面）
// 左侧栏入口 + 整页：内网/外网按钮、二维码、倒计时、设置
// 全部数据来自本机程序 http://127.0.0.1:14930
window.__ModuleLoader__.load({
  id: "dsh-connector",
  factory: function (require) {
    var module = { exports: {} };
    var exports = module.exports;

    // require("react") 返回的是 ESM 命名空间，真正的 React 在 .default 上
    var reactMod = require("react");
    var React = (reactMod && reactMod.default) ? reactMod.default : reactMod;
    var h = React.createElement;
    var useState = React.useState;
    var useEffect = React.useEffect;
    try {
      console.log("[dsh-connector] client bundle loaded, react keys=" + Object.keys(React || {}).join(","));
    } catch (e) {}

    var API = "http://127.0.0.1:14930";
    var EXPECTED_API = 1;
    var AUTHOR = "你发鸡盲吗？";
    var DOUYIN = "22519731810";
    var QQ = "1097551433";

    var S = {
      wrap: { padding: "22px 26px", maxWidth: 760, margin: "0 auto", fontFamily: "inherit" },
      h1: { fontSize: 18, fontWeight: 600, margin: "0 0 4px" },
      sub: { fontSize: 12, color: "#6b7280", marginBottom: 16 },
      row: { display: "flex", gap: 10, marginBottom: 14 },
      btn: {
        flex: 1, padding: "10px 14px", fontSize: 13, cursor: "pointer",
        border: "1px solid var(--dsw-alias-border-l1, #d0d7de)", borderRadius: 8,
        background: "transparent", color: "inherit"
      },
      btnPrimary: {
        flex: 1, padding: "10px 14px", fontSize: 13, cursor: "pointer", fontWeight: 600,
        border: "1px solid #1f6feb", borderRadius: 8, background: "#1f6feb", color: "#fff"
      },
      btnDanger: {
        padding: "8px 12px", fontSize: 12, cursor: "pointer",
        border: "1px solid #f0b4ae", borderRadius: 8, background: "transparent", color: "#b42318"
      },
      btnSmall: {
        padding: "6px 10px", fontSize: 12, cursor: "pointer",
        border: "1px solid var(--dsw-alias-border-l1, #d0d7de)", borderRadius: 6,
        background: "transparent", color: "inherit"
      },
      card: {
        border: "1px solid var(--dsw-alias-border-l1, #d0d7de)", borderRadius: 10,
        padding: "14px 16px", marginBottom: 14
      },
      label: { fontSize: 11, color: "#6b7280", marginBottom: 8 },
      qrBox: { textAlign: "center", padding: "6px 0" },
      qr: { width: 240, height: 240, border: "1px solid #e5e7eb", borderRadius: 8, background: "#fff" },
      link: {
        width: "100%", marginTop: 8, padding: "9px 10px", fontSize: 11,
        fontFamily: "Consolas, monospace", border: "1px solid #d0d7de", borderRadius: 8,
        background: "rgba(127,127,127,0.06)", color: "inherit", resize: "vertical", minHeight: 46
      },
      settingRow: { display: "flex", alignItems: "center", justifyContent: "space-between", marginTop: 10 },
      select: {
        padding: "6px 8px", fontSize: 12, borderRadius: 6,
        border: "1px solid var(--dsw-alias-border-l1, #d0d7de)",
        background: "transparent", color: "inherit"
      },
      note: {
        fontSize: 11, lineHeight: 1.55, color: "#6b7280", marginTop: 8,
        padding: "8px 10px", border: "1px dashed var(--dsw-alias-border-l1, #d0d7de)", borderRadius: 8
      },
      dot: function (ok) {
        return {
          display: "inline-block", width: 8, height: 8, borderRadius: "50%",
          marginRight: 6, background: ok ? "#16a34a" : "#dc2626"
        };
      },
      err: { fontSize: 12, color: "#b42318", marginTop: 8, minHeight: 16 },
      ok: { fontSize: 12, color: "#15803d", marginTop: 8, minHeight: 16 }
    };

    var NOTES = {
      A: "A：5 分钟内显示二维码，到期后界面隐藏，但链接本身一直可用（直到点「停用」）。自己长期用最方便。",
      B: "B：到期后界面隐藏，并拒绝新的连接；已经连着的设备不受影响。退出浏览器后再用旧链接进不来，需重新生成。",
      C: "C：到期后强制断开所有设备，必须重新生成二维码才能再连。最严格。"
    };
    // A 策略的风险提示（单独渲染成红字）
    var NOTES_WARN = { A: "引擎会常挂公网，建议改用 B 策略" };

    function apiGet(path) {
      return fetch(API + path, { cache: "no-store" }).then(function (r) { return r.json(); });
    }
    function apiPost(path) {
      return fetch(API + path, { method: "POST" }).then(function (r) { return r.json(); });
    }
    function apiSettings(body) {
      return fetch(API + "/api/settings", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body)
      }).then(function (r) { return r.json(); });
    }

    function versionAlert(d) {
      var v = d && d.apiVersion;
      var lines = [
        "版本过低",
        "",
        "连接器程序：" + ((d && d.programVersion) || "未知（过旧的版本）"),
        "程序 API：" + (typeof v === "undefined" ? "缺失" : "v" + v),
        "本插件需要：API v" + EXPECTED_API,
        "",
        "程序与插件版本不匹配，请更新 DSH 连接器后重试。",
        "",
        "更新请联系作者：",
        AUTHOR,
        "抖音：" + DOUYIN,
        "QQ：" + QQ
      ];
      try { window.alert(lines.join("\n")); } catch (e) {}
    }

    function ConnectorIcon() {
      return h("span", { style: { fontSize: 15, lineHeight: 1 } }, "\uD83D\uDCF6");
    }

    function ConnectorPage() {
      var s0 = useState(null), st = s0[0], setSt = s0[1];
      var e0 = useState(""), err = e0[0], setErr = e0[1];
      var m0 = useState(""), msg = m0[0], setMsg = m0[1];
      var b0 = useState(false), busy = b0[0], setBusy = b0[1];
      var q0 = useState(0), qrTick = q0[0], setQrTick = q0[1];
      var l0 = useState(0), left = l0[0], setLeft = l0[1];
      var w0 = useState(false), warned = w0[0], setWarned = w0[1];
      var d0 = useState(""), modeTag = d0[0], setModeTag = d0[1];
      var rf0 = useState(false), refreshing = rf0[0], setRefreshing = rf0[1];
      var rm0 = useState(""), refreshMsg = rm0[0], setRefreshMsg = rm0[1];

      function applyStatus(d) {
        setSt(d);
        setErr("");
        if (d && d.state && d.state.expiresAt) {
          setLeft(Math.max(0, Math.floor((d.state.expiresAt - Date.now()) / 1000)));
        }
        // 用服务端的 lastAction 校正当前显示的是哪条通道（避免刷新后跳回上一条）
        if (d && d.state) {
          var last = d.state.lastAction;
          if (last === "wan" && d.state.wan && d.state.wan.on && d.state.wan.url) setModeTag("外网");
          else if (last === "lan" && d.state.lan && d.state.lan.on && d.state.lan.url) setModeTag("内网");
          else if (last === "stop") setModeTag("");
        }
      }

      function refresh() {
        return apiGet("/api/status").then(function (d) {
          applyStatus(d);
          if (d && d.settings) {
            // 不覆盖用户正在编辑的下拉，只在首次同步
            if (!st) setSt(d);
          }
        }).catch(function () {
          setSt(null);
        });
      }

      // 手动刷新：按钮先进入「刷新中」，等 fetch 真正返回后才给结果（带时间戳和耗时）
      function doRefresh() {
        if (refreshing) return;
        setRefreshing(true);
        setRefreshMsg("刷新中…");
        var t0 = Date.now();
        apiGet("/api/status").then(function (d) {
          setRefreshing(false);
          if (d && d.ok) {
            applyStatus(d);
            var n = new Date();
            var hh = ("0" + n.getHours()).slice(-2);
            var mi = ("0" + n.getMinutes()).slice(-2);
            var ss = ("0" + n.getSeconds()).slice(-2);
            setRefreshMsg("已刷新 " + hh + ":" + mi + ":" + ss + " · 用时 " + (Date.now() - t0) + "ms");
          } else {
            setRefreshMsg("刷新失败：服务返回异常（" + (Date.now() - t0) + "ms）");
          }
        }).catch(function () {
          setRefreshing(false);
          setRefreshMsg("刷新失败：连接器程序未运行（" + (Date.now() - t0) + "ms）");
        });
      }

      function start(mode) {
        if (busy) return;
        setBusy(true);
        setErr("");
        // 立即切换界面状态：否则等待期间一直显示上一条通道的二维码/链接
        setModeTag(mode === "lan" ? "内网" : "外网");
        setQrTick(0);
        setLeft(0);
        setMsg(mode === "lan" ? "正在启动内网通道…" : "正在建立外网隧道（约 10–15 秒）…");
        apiPost("/api/start?mode=" + mode).then(function (d) {
          setBusy(false);
          if (d && d.ok) {
            setMsg((mode === "lan" ? "内网" : "外网") + "已就绪");
            setModeTag(mode === "lan" ? "内网" : "外网");
            setQrTick(Date.now());
            setLeft(Math.max(0, Math.floor((d.expiresAt - Date.now()) / 1000)));
            refresh();
          } else {
            setMsg("");
            // 失败时做版本诊断
            var v = d && d.apiVersion;
            if (typeof v === "undefined" || v !== EXPECTED_API) {
              if (!warned) { setWarned(true); versionAlert(d || {}); }
            }
            setErr("失败：" + ((d && d.error) || "未知错误"));
          }
        }).catch(function () {
          setBusy(false);
          setMsg("");
          setErr("连接器程序未运行。请先双击桌面「DSH连接器」，再回来点按钮。");
        });
      }

      // 停用前先列出真实在跑的通道，再确认
      function stopAll() {
        apiGet("/api/status").then(function (d) {
          if (!d || !d.ok) { setErr("无法获取通道状态：连接器程序未运行"); return; }
          var lanOn = d.state && d.state.lan && d.state.lan.on;
          var wanOn = d.state && d.state.wan && d.state.wan.on;
          var names = [], details = [];
          if (lanOn) { names.push("内网"); details.push("· 内网  " + (d.state.lan.url || "192.168.1.2:14925")); }
          if (wanOn) { names.push("外网"); details.push("· 外网  https://" + (d.state.wan.domain || "?")); }
          if (names.length === 0) { setMsg("当前没有正在运行的通道，无需停用"); return; }
          var head = (names.length === 2) ? "内网和外网都在运行" : (names[0] + "正在运行");
          var msg = head + "\n\n" + details.join("\n") + "\n\n停止后，" + names.join("和") + "通道上已连接的设备会立刻断开。\n确认停止吗？";
          if (!window.confirm(msg)) return;
          apiPost("/api/stop").then(function (r) {
            if (r && r.ok) { setMsg("已停用 " + names.join("和") + "，所有连接已断开"); setQrTick(0); setLeft(0); setModeTag(""); refresh(); }
            else setErr("停用失败");
          }).catch(function () { setErr("连接器程序未运行。"); });
        }).catch(function () { setErr("连接器程序未运行。"); });
      }

      function save(patch) {
        var cur = (st && st.settings) || {};
        var body = {
          display: patch.display || cur.display || "both",
          windowMinutes: typeof patch.windowMinutes === "number" ? patch.windowMinutes : (cur.windowMinutes || 5),
          expiryMode: patch.expiryMode || cur.expiryMode || "B",
          channelMode: patch.channelMode || cur.channelMode || "exclusive"
        };
        apiSettings(body).then(function (d) {
          if (d && d.ok) { setMsg("设置已保存"); refresh(); }
        }).catch(function () { setErr("设置保存失败：程序未运行"); });
      }

      useEffect(function () {
        refresh();
        var t = setInterval(function () {
          if (st && st.state && st.state.expiresAt) {
            setLeft(Math.max(0, Math.floor((st.state.expiresAt - Date.now()) / 1000)));
          }
        }, 1000);
        var p = setInterval(refresh, 5000);
        return function () { clearInterval(t); clearInterval(p); };
      }, []);

      var settings = (st && st.settings) || {};
      var state = (st && st.state) || {};
      var engineUp = !!state.engineUp;
      var isDual = ((settings.channelMode || "exclusive") === "dual");
      var hasQr = left > 0 && qrTick > 0;
      var mins = Math.floor(left / 60), secs = left % 60;

      var statusText = st ? (engineUp ? "引擎在线" : "引擎离线（请先打开 DeepSeek）") : "连接器程序未运行";

      return h("div", { style: S.wrap },
        h("div", { style: S.h1 }, "DSH 连接器"),
        h("div", { style: S.sub },
          h("span", { style: S.dot(!!st && engineUp) }),
          statusText,
          modeTag ? h("span", { style: { marginLeft: 10, color: "#1f6feb" } }, "· " + modeTag) : null
        ),

        h("div", { style: S.row },
          h("button", { style: busy ? S.btn : S.btnPrimary, disabled: busy, onClick: function () { start("lan"); } }, "内网（同一 WiFi）"),
          h("button", { style: busy ? S.btn : S.btnPrimary, disabled: busy, onClick: function () { start("wan"); } }, "外网（流量/异地）")
        ),

        h("div", { style: S.card },
          h("div", { style: S.label }, isDual ? "扫码入口（双通：内网 + 外网）" : ("扫码入口" + (modeTag ? " · " + modeTag : ""))),
          isDual
            ? h("div", { style: { display: "flex", gap: 14, justifyContent: "center", padding: "4px 0" } },
                (state.lan && state.lan.url)
                  ? h("div", { style: { flex: 1, textAlign: "center" } },
                      h("div", { style: { fontSize: 11, color: "#1f6feb", marginBottom: 4, fontWeight: 600 } }, "内网"),
                      h("img", { src: API + "/qr.png?mode=lan&t=" + qrTick, style: { width: 170, height: 170, border: "1px solid #e5e7eb", borderRadius: 8, background: "#fff" } }),
                      h("div", { style: { fontSize: 10, color: "#9ca3af", marginTop: 4, wordBreak: "break-all", maxHeight: 28, overflow: "hidden" } }, state.lan.url)
                    )
                  : h("div", { style: { flex: 1, textAlign: "center", color: "#9ca3af", fontSize: 11, paddingTop: 70 } }, "内网未开启"),
                (state.wan && state.wan.url)
                  ? h("div", { style: { flex: 1, textAlign: "center" } },
                      h("div", { style: { fontSize: 11, color: "#8250df", marginBottom: 4, fontWeight: 600 } }, "外网"),
                      h("img", { src: API + "/qr.png?mode=wan&t=" + qrTick, style: { width: 170, height: 170, border: "1px solid #e5e7eb", borderRadius: 8, background: "#fff" } }),
                      h("div", { style: { fontSize: 10, color: "#9ca3af", marginTop: 4, wordBreak: "break-all", maxHeight: 28, overflow: "hidden" } }, state.wan.url)
                    )
                  : h("div", { style: { flex: 1, textAlign: "center", color: "#9ca3af", fontSize: 11, paddingTop: 70 } }, "外网未开启")
              )
            : h("div", { style: S.qrBox },
                hasQr
                  ? h("img", { src: API + "/qr.png" + (modeTag === "外网" ? "?mode=wan" : "?mode=lan") + "&t=" + qrTick, style: S.qr, alt: "二维码" })
                  : h("div", { style: { color: "#9ca3af", fontSize: 12, padding: "100px 0" } }, "点击上方按钮生成二维码")
              ),
          hasQr
            ? h("div", { style: { textAlign: "center", fontSize: 12, color: "#b45309", marginTop: 8 } },
                "剩余 " + mins + ":" + (secs < 10 ? "0" + secs : secs) + "（到期后需重新生成）")
            : null,
          (hasQr && !isDual && (settings.display === "both" || settings.display === "text"))
            ? h("textarea", {
                style: S.link, readOnly: true,
                value: (modeTag === "内网") ? ((state.lan && state.lan.url) || "") : ((state.wan && state.wan.url) || "")
              })
            : null,
          (isDual && (settings.display === "both" || settings.display === "text"))
            ? h("textarea", {
                style: S.link, readOnly: true,
                value: ((state.lan && state.lan.url) ? ("内网: " + state.lan.url + "\n") : "") + ((state.wan && state.wan.url) ? ("外网: " + state.wan.url) : "")
              })
            : null,          msg ? h("div", { style: S.ok }, msg) : null,
          err ? h("div", { style: S.err }, err) : null
        ),

        h("div", { style: S.card },
          h("div", { style: S.label }, "设置"),
          h("div", { style: S.settingRow },
            h("span", { style: { fontSize: 13 } }, "显示方式"),
            h("select", {
              style: S.select, value: settings.display || "both",
              onChange: function (e) { save({ display: e.target.value }); }
            },
              h("option", { value: "both" }, "二维码 + 文本链接"),
              h("option", { value: "qr" }, "仅二维码"),
              h("option", { value: "text" }, "仅文本链接")
            )
          ),
          h("div", { style: S.settingRow },
            h("span", { style: { fontSize: 13 } }, "二维码有效期（分钟）"),
            h("input", {
              type: "number", min: 1, max: 60, value: settings.windowMinutes || 5,
              style: { width: 72, padding: "6px 8px", fontSize: 12, borderRadius: 6, border: "1px solid #d0d7de", background: "transparent", color: "inherit" },
              onChange: function (e) { save({ windowMinutes: Number(e.target.value) || 5 }); }
            })
          ),
          h("div", { style: S.settingRow },
            h("span", { style: { fontSize: 13 } }, "过期策略"),
            h("select", {
              style: S.select, value: settings.expiryMode || "B",
              onChange: function (e) { save({ expiryMode: e.target.value }); }
            },
              h("option", { value: "A" }, "A · 长期有效（想断就点「停用」）"),
              h("option", { value: "B" }, "B · 拒绝新连接（过期后要重新点按钮）"),
              h("option", { value: "C" }, "C · 全部断开（每 5 分钟要重连一次）")
            )
          ),
          h("div", { style: S.settingRow },
            h("span", { style: { fontSize: 13 } }, "通道模式"),
            h("select", {
              style: S.select, value: settings.channelMode || "exclusive",
              onChange: function (e) { save({ channelMode: e.target.value }); }
            },
              h("option", { value: "exclusive" }, "互斥（只留一条，单个二维码）"),
              h("option", { value: "dual" }, "双通（内网+外网，两个二维码）")
            )
          ),
          h("div", { style: S.note },
            (settings.channelMode === "dual")
              ? "双通：内网和外网同时开启，各自一个二维码并排显示。适合一边局域网一边远程。"
              : "互斥：点内网就关外网，点外网就关内网，始终只有一个二维码。更安全。"),
          h("div", { style: S.note },
            NOTES[settings.expiryMode || "B"],
            NOTES_WARN[settings.expiryMode]
              ? h("div", { style: { color: "#b42318", fontWeight: 600, marginTop: 4 } },
                  "⚠ " + NOTES_WARN[settings.expiryMode])
              : null
          ),
          h("div", { style: { ...S.row, marginTop: 12, marginBottom: 0 } },
            h("button", { style: S.btnDanger, onClick: stopAll }, "停用并断开所有连接"),
            h("button", {
              style: refreshing ? { ...S.btnSmall, opacity: 0.6, cursor: "default" } : S.btnSmall,
              disabled: refreshing,
              onClick: doRefresh
            }, refreshing ? "刷新中…" : "刷新状态")
          )
        ),

        refreshMsg
          ? h("div", { style: {
              fontSize: 11, textAlign: "center", marginTop: 4,
              color: refreshMsg.indexOf("失败") >= 0 ? "#b42318" : "#15803d"
            } }, refreshMsg)
          : null,
        h("div", { style: { fontSize: 11, color: "#9ca3af", textAlign: "center", marginTop: 6 } },
          "整合作者：" + AUTHOR + "　抖音：" + DOUYIN + "　QQ：" + QQ)
      );
    }

    function apply(ctx) {
      ctx.slots.inject("sidebar.panellist", function () {
        return ctx.slots.register(
          { name: "sidebar.panellist", id: "dsh-connector", order: 40, label: "连接器" },
          ConnectorIcon
        );
      });
      ctx.slots.inject("main", function () {
        return ctx.slots.register(
          { name: "main", key: "dsh-connector" },
          ConnectorPage
        );
      });
    }

    exports.apply = apply;
    exports.inject = ["slots"];
    exports.ConnectorPage = ConnectorPage;
    exports.ConnectorIcon = ConnectorIcon;
    return module.exports;
  }
});
