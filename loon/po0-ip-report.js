/*
  po0 直连出口 IP 上报。
  必须用 node=DIRECT，上报的是本机真实出口，不是代理节点 IP。
*/

function arg(name, fallback) {
  if ($argument && $argument[name] != null && String($argument[name]) !== "") {
    return String($argument[name]);
  }
  return fallback;
}

const host = arg("host", "");
const port = arg("port", "41741");
const token = arg("token", "");
const notify = !( $argument && ($argument.notify === false || $argument.notify === "false") );

function done() {
  $done();
}

function fail(message) {
  console.log("po0 report fail: " + message);
  if (notify) {
    $notification.post("po0 加白失败", "", message);
  }
  done();
}

function report() {
  if (!host || !token) {
    fail("请在插件参数里填写 po0 地址和 Token");
    return;
  }
  const url = "http://" + host + ":" + port + "/report";
  $httpClient.post(
    {
      url: url,
      timeout: 8000,
      headers: {
        Authorization: "Bearer " + token,
        "Content-Type": "application/json",
      },
      body: "{}",
      node: "DIRECT",
    },
    function (error, response, data) {
      if (error) {
        fail(String(error));
        return;
      }
      const status = response && response.status;
      let payload = {};
      try {
        payload = JSON.parse(data || "{}");
      } catch (e) {
        payload = {};
      }
      if (status !== 200 || !payload.ok) {
        fail("HTTP " + status + " " + (payload.error || data || ""));
        return;
      }
      const ip = String(payload.ip || "");
      const last = $persistentStore.read("po0_last_ip") || "";
      if (ip && ip !== last) {
        $persistentStore.write(ip, "po0_last_ip");
        if (notify) {
          $notification.post("po0 已加白", "", ip);
        }
      }
      console.log("po0 report ok: " + ip);
      done();
    }
  );
}

report();
