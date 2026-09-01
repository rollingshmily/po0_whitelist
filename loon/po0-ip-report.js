/*
  把 DIRECT 出口 IP 报到海外信箱，不打国内防火墙机器。
*/

function arg(name, fallback) {
  if ($argument && $argument[name] != null && String($argument[name]) !== "") {
    return String($argument[name]);
  }
  return fallback;
}

const defaultPort = arg("port", "18443");
const notify = !($argument && ($argument.notify === false || $argument.notify === "false"));

function parseTargets() {
  const targets = [];
  const host = arg("host", "");
  const token = arg("token", "");
  if (host && token) {
    targets.push({ host: host, port: defaultPort, token: token });
  }
  arg("extra", "")
    .split(/[\n,;]+/)
    .forEach(function (line) {
      line = String(line || "").trim();
      if (!line || line.indexOf("#") === 0) {
        return;
      }
      const parts = line.split("|").map(function (part) {
        return part.trim();
      });
      if (parts.length === 2) {
        targets.push({ host: parts[0], port: defaultPort, token: parts[1] });
        return;
      }
      if (parts.length >= 3) {
        targets.push({ host: parts[0], port: parts[1] || defaultPort, token: parts[2] });
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
        Authorization: "Bearer " + target.token,
        "Content-Type": "application/json",
      },
      body: "{}",
      node: "DIRECT",
    },
    function (error, response, data) {
      if (error) {
        callback("上报失败");
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
        callback("上报失败");
        return;
      }
      const ip = String(payload.ip || "");
      const key = storeKey(target);
      const last = $persistentStore.read(key) || "";
      if (ip && ip !== last) {
        $persistentStore.write(ip, key);
        if (notify) {
          $notification.post("po0 已加白", "", ip);
        }
      }
      console.log("po0 mailbox ok " + ip);
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
      console.log("po0 mailbox fail: " + error);
      errors.push(error);
    }
    runQueue(targets, index + 1, errors);
  });
}

const targets = parseTargets();
if (!targets.length) {
  if (notify) {
    $notification.post("po0 加白失败", "", "请填写信箱地址和 Token");
  }
  $done();
} else {
  runQueue(targets, 0, []);
}
