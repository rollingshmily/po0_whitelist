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

function failText(error, response, data) {
  if (error) {
    return String(error);
  }
  const status = response && response.status;
  let payload = {};
  try {
    payload = JSON.parse(data || "{}");
  } catch (e) {
    payload = {};
  }
  if (payload && payload.error) {
    return "HTTP " + status + " " + payload.error;
  }
  return "HTTP " + status;
}

function postOnce(target, callback) {
  const url = "http://" + target.host + ":" + target.port + "/report";
  $httpClient.post(
    {
      url: url,
      timeout: 15000,
      headers: {
        Authorization: "Bearer " + target.token,
        "Content-Type": "application/json",
      },
      body: "{}",
      node: "DIRECT",
    },
    function (error, response, data) {
      const status = response && response.status;
      let payload = {};
      try {
        payload = JSON.parse(data || "{}");
      } catch (e) {
        payload = {};
      }
      if (error || status !== 200 || !payload.ok) {
        callback(failText(error, response, data));
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

function postOne(target, callback) {
  postOnce(target, function (error) {
    if (!error) {
      callback(null);
      return;
    }
    console.log("po0 mailbox retry after: " + error);
    const retry = function () {
      postOnce(target, callback);
    };
    if (typeof setTimeout === "function") {
      setTimeout(retry, 1500);
    } else {
      retry();
    }
  });
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
