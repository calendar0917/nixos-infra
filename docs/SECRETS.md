# Secrets 与恢复密码

## 原则

- 明文只存在于编辑器、`/run/secrets/*` 和受保护的离线介质。
- Git 只提交 `ENC[...]` 密文；Nix store 只包含密文路径或运行时路径。
- age 私钥不进入仓库、不进入 Nix store、不进入 shell 历史。
- Restic 密码独立于 SOPS；恢复 Restic 时不要求先解密 SOPS。

## sops-nix 配置

`modules/secrets.nix` 固定：

```nix
sops.age.keyFile = "/var/lib/sops-nix/keys.txt";
```

该路径由 root 拥有、权限 `0600`。安装：

```bash
sudo install -d -m 0700 /var/lib/sops-nix
sudo install -m 0600 /offline/media/age-keys.txt /var/lib/sops-nix/keys.txt
```

`secrets/secrets.yaml` 只存放加密值。查看/编辑：

```bash
sops secrets/secrets.yaml
```

编辑时 sops 会在临时文件中短暂解密；不要把临时文件复制到仓库、聊天记录或日志。
构建时 sops-nix 不会打印明文；使用时只在 `/run/secrets/<name>` 出现。

## 当前 secret

`secrets/secrets.yaml` 目前只有：

```text
mihomo-config
```

`modules/network.nix` 在 `my.network.mihomo.enable = true` 时声明
`sops.secrets."mihomo-config"`，并设置：

```nix
owner = "root";
group = "root";
mode = "0400";
restartUnits = [ "mihomo.service" ];
```

然后 `services.mihomo.configFile` 指向这个运行时路径。没有把配置复制到
`/nix/store` 的 `configFile`。

## age recipient

`.sops.yaml` 中的 recipient 必须与目标机的私钥匹配。更换密钥后：

```bash
# 在安全环境生成新密钥（如果确实需要）
age-keygen -o age-keys.txt
# 将输出的 public key 写入 .sops.yaml，然后：
sops updatekeys secrets/secrets.yaml
```

`secrets/secrets.yaml.example` 只是模板，不是可用配置；不要把真实订阅替换后提交为
明文。

## Restic 密码（独立恢复链）

Restic 密码文件：

```text
/var/lib/secrets/restic-password
```

由 `modules/backup.nix` 以 `passwordFile` 传给 restic。它不经过 SOPS，因此：

- 系统盘损坏时，只要 USB 和离线密码还在，就能恢复；
- age 私钥丢失不会阻止读取 Restic 仓库；
- 但 Restic 密码本身必须单独离线保存，不能只放在系统盘。

旧 dotfiles 中 `config/common/backup/restic-password` 是 Git 跟踪的明文文件。若它
对应真实仓库密码，应立即轮换，并在新仓库中只保留 `/var/lib/secrets` 的运行时副本。

## 禁止事项

- 不要把 age 私钥、Restic 密码、Mihomo 订阅 URL、Wi-Fi 密码写入 `.nix` 文件。
- 不要用 `builtins.readFile` 读取 secret 再赋值给服务配置。
- 不要把 secret 放进 `environment.systemPackages` 或 `systemd.services.*.environment`。
- 不要把 `/run/secrets` 内容复制到 `/home` 后提交。
