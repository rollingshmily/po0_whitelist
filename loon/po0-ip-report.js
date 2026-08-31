/*
  po0 直连出口 IP 上报。
  必须用 node=DIRECT。支持一台或多台机器顺序上报。
*/

function arg(name, fallback) {
  if ($argument && $argument[name] != null && String($argument[name]) !== "") {
    return String($argument[name]);
  }
  return fallback;
}

const defaultPort = arg("port", "41741");
const notify = !($argument && ($argument.notify === false || $argument.notify === "false"));

function parseTargets() {
  const targets = [];
  const host = arg("host", "");
  const token = arg("token", "");
  if (host && token) {
    targets.push({ host: host, port: defaultPort, token: token });
  }
  const extra = arg("extra", "");
  extra.split(/[\n,;]+/).forEach(function (line) {
    line = String(line || "").trim();
    if (!line || line.indexOf("#") === 0) {
      return;
    }
    const parts = line.split("|").map(function (part) {
      return part.trim();
    });
    if (parts.length === 1 && parts[0].indexOf(" ") >= 0) {
      const spaced = parts[0].split(/\s+/);
      parts.length = 0;
      spaced.forEach(function (item) {
        parts.push(item);
      });
    }
    if (parts.length === 2) {
      targets.push({ host: parts[0], port: defaultPort, token: parts[1] });
      return;
    }
    if (parts.length >= 3) {
      targets.push({
        host: parts[0],
        port: parts[1] || defaultPort,
        token: parts[2],
      });
    }
  });
  const seen = {};
  return targets.filter(function (item) {
    if (!item.host || !item.token) {
      return false;
    }
    const key = item.host + ":" + item.port;
    if (seen[key]) {
      return false;
    }
    seen[key] = true;
    return true;
  });
}

function storeKey(target) {
  return "po0_last_ip_" + target.host + "_" + target.port;
}

function postOne(target, callback) {
  const url = "http://" + target.host + ":" + target.port + "/report";
  $httpClient.post(
    {
      url: url,
      timeout: 8000,
      headers: {
        Authorization: "***" + target.token,
        "Content-Type": "application/json",
      },
      body: "{}",
      node: "DIRECT",
    },
    function (error, response, data) {
      if (error) {
        callback(target.host + " " + error);
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
        callback(target.host + " HTTP " + status + " " + (payload.error || data || ""));
        return;
      }
      const ip = String(payload.ip || "");
      const key = storeKey(target);
      const last = $persistentStore.read(key) || "";
      if (ip && ip !== last) {
        $persistentStore.write(ip, key);
        if (notify) {
          $notification.post("po0 已加白", target.host, ip);
        }
      }
      console.log("po0 report ok: " + target.host + " " + ip);
      callback(null);
    }
  );
}

function runQueue(targets, index, errors) {
  if (index >= targets.length) {
    if (errors.length && notify) {
      $notification.post("po0 加白失败", "", errors.join(" | "));
    }
    $done();
    return;
  }
  postOne(targets[index], function (error) {
    if (error) {
      console.log("po0 report fail: " + error);
      errors.push(error);
    }
    runQueue(targets, index + 1, errors);
  });
}

const targets = parseTargets();
if (!targets.length) {
  if (notify) {
    $notification.post("po0 加白失败", "", "请填写至少一台 po0 的地址和 Token");
  }
  $done();
} else {
  runQueue(targets, 0, []);
}
