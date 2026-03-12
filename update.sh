#!/bin/bash
set -euo pipefail

# 全局环境变量，确保所有的 apt-get 都是完全静默执行，无交互弹窗
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

# 日志辅助函数
log_info() {
    echo -e "\033[32m[INFO]\033[0m $1"
}

log_error() {
    echo -e "\033[31m[ERROR]\033[0m $1" >&2
}

# 检查 root 权限
if [[ $EUID -ne 0 ]]; then
    log_error "请使用 sudo 运行此脚本"
    exit 1
fi

log_info ">>> 开始环境检查与清理..."

# 1. 更新软件源
apt-get update -y

# 2. 修复可能损坏的依赖关系
apt-get --fix-broken install -y

# 3. 自动清理无用的孤儿包
apt-get autoremove -y

# 4. 清理本地下载缓存（释放空间，非常安全）
apt-get clean

log_info ">>> 环境准备完毕，开始执行安装任务！"

# 变量定义
GITHUB_USER="JzCharizard"
GITHUB_REPO="jzzn_update_sentinel"
BRANCH="main"
RELEASE_TAG="v1.0.0"

# GitHub Raw 文件直连地址 (用于读取脚本等单文件)
BASE_URL="https://raw.githubusercontent.com/$GITHUB_USER/$GITHUB_REPO/$BRANCH"

# GitHub Release 附件下载地址 (用于下载打包好的压缩包或二进制文件)
RELEASE_URL="https://github.com/$GITHUB_USER/$GITHUB_REPO/releases/download/$RELEASE_TAG"

# 自动清理临时目录
WORK_DIR=$(mktemp -d /tmp/deploy_XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

log_info "开始更新..."

# 探测安装路径
CTRL_HOME=""
for dir in "/home/jzzn/controller-1.0.0" "/root/controller-1.0.0"; do
    if [[ -d "$dir" ]]; then
        CTRL_HOME="$dir"
        break
    fi
done

if [[ -z "$CTRL_HOME" ]]; then
    log_error "未找到 controller-1.0.0 目录！"
    exit 1
fi
log_info "controller路径: $CTRL_HOME"

# 进入工作目录
cd "$WORK_DIR"

log_info "正在通过 apt 安装 p7zip-full 及相关依赖..."
# 更新源并安装依赖
apt-get update -qq 
apt-get --fix-broken install -y
apt-get install -y jq libjq1 libonig5
if ! apt-get install -y p7zip-full  2>&1; then
    log_info "apt 安装失败，尝试修复依赖..."
    apt-get install -f -y 
    apt-get install -y p7zip-full 
fi

if ! command -v 7z &> /dev/null; then
    log_error "p7zip 安装失败，请检查系统环境或网络连接"
    exit 1
fi
log_info "p7zip 安装成功。"

# 下载加密的 7z 包
TAR_FILE="sentinel_update.7z"
log_info "正在下载加密部署包..."
wget --quiet --show-progress "$RELEASE_URL/$TAR_FILE" -O "$TAR_FILE"

# 初始化成功状态标志
EXTRACT_SUCCESS=false

for ((i=1; i<=3; i++)); do
    echo "请输入 7z 压缩包解压密码 (第 $i/3 次):"
    read -rs ZIP_PASSWORD </dev/tty
    echo "" # 换行输出

    if [[ -z "$ZIP_PASSWORD" ]]; then
        log_info "未检测到输入，请重新输入。"
        continue
    fi

    log_info "正在尝试解密文件..."
    
    # 执行解压过程
    if 7z x "$TAR_FILE" -p"$ZIP_PASSWORD" -o"$WORK_DIR" -y > /dev/null 2>&1; then
        log_info "✅ 部署包已成功解密并解压。"
        log_info "内容位于: $WORK_DIR"
        ls -lh "$WORK_DIR"
        
        EXTRACT_SUCCESS=true
        break 
    else
        REMAINING=$((3 - i))
        if [[ $REMAINING -gt 0 ]]; then
            log_error "密码错误，您还有 $REMAINING 次机会。"
        fi
    fi
done

# 如果尝试 3 次后依然没有成功，则终止脚本
if [[ "$EXTRACT_SUCCESS" == "false" ]]; then
    log_error "已连续 3 次尝试失败，操作已终止。"
    exit 1
fi
log_info "更新包下载及解压完毕。"

echo "------------------------------------------------"
log_info "开始录入设备信息："
read -p "请输入设备型号 (0=风系, 1=林系, 3=山系, 4=云系): " DEV_TYPE </dev/tty
if [[ ! "$DEV_TYPE" =~ ^[0134]$ ]]; then
    log_error "无效的设备型号，操作已终止。"
    exit 1
fi

echo "------------------------------------------------"
log_info "当前系统磁盘信息如下："
df -h
echo "------------------------------------------------"
read -p "请输入目标设备名称 (如 sda2): " DEVICE_NAME </dev/tty
if [[ -z "$DEVICE_NAME" ]]; then
    log_error "未输入设备名，操作已终止。"
    exit 1
fi
echo "------------------------------------------------"
log_info "信息录入完毕，开始全自动部署..."
# =========================================================================

# 进入解压后的目录
cd ./sentinel_update/

# 处理换行符，排除 .jar 等可能由于转码损坏的二进制文件
# find . -maxdepth 1 -type f ! -name "*.jar" ! -name "*.file" -exec sed -i 's/\r$//' {} +

DB_USER=$(jq -r '.database.user' config.json)
DB_NAME=$(jq -r '.database.name' config.json)
DB_PASS=$(jq -r '.database.pass' config.json)

# SQL 执行函数
exec_sql() {
    PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -d "$DB_NAME" -c "$1"
}

# 1. 部署系统服务与脚本
install -m 755 -o root -g root sniff sniff_daemon /etc/init.d/
install -m 755 -o root -g root editRange.sh cleanup.sh loginpolicy.sql pwdpolicy.sql /home/jzzn/
install -m 755 -o root -g root check_net.sh /etc/init.d/
install -m 644 -o root -g root logrotate.d/sniff /etc/logrotate.d/
install -m 755 -o root -g root rc.local /etc/rc.local

[ -n "$(tail -c1 /etc/rc.local)" ] && echo "" >> /etc/rc.local
printf '%s\n' "${CTRL_HOME}/bin/start &" >> /etc/rc.local

# 2. 数据库更新
# 更新配置
exec_sql "UPDATE public.global_configuration SET value='{\"cpu_info\": 1, \"cpu_warning\": 70, \"cpu_error\": 90, \"mem_info\": 1, \"mem_warning\": 70, \"mem_error\": 90, \"hd_info\": 1, \"hd_warning\": 70, \"hd_error\": 90}' WHERE name='ctl_config';"

# 插入操作权限 (使用 DO 块避免重复插入报错，或者直接忽略错误)
PGPASSWORD="$DB_PASS" psql -U "$DB_USER" -d "$DB_NAME" <<EOF
INSERT INTO public.operation (ability, level, display_zh, display_en) VALUES 
('url:/restful/sdwan/device/conf/policy/ctl,method:get', 0, '查询控制配置', 'Query Control Configuration'),
('url:/restful/sdwan/device/conf/policy/ctl,method:put', 1, '修改控制配置', 'Modify Control Configuration')
ON CONFLICT DO NOTHING;

INSERT INTO public.role_operations (role_name, operation) VALUES 
('SystemAdministrator', 'url:/restful/sdwan/device/conf/policy/ctl,method:get'),
('SystemAdministrator', 'url:/restful/sdwan/device/conf/policy/ctl,method:put'),
('policy', 'url:/restful/sdwan/device/conf/policy/ctl,method:get'),
('policy', 'url:/restful/sdwan/device/conf/policy/ctl,method:put')
ON CONFLICT DO NOTHING;
EOF

# 3. 更新应用
cp -ruv controller-1.0.0/. "${CTRL_HOME}/"

# 4. 禁用 APT 更新 (已修正文件名拼写错误)
chmod +x disable_APT_Update.sh
ls
./disable_APT_Update.sh

# 5. 设置系统
timedatectl set-timezone Asia/Shanghai

# 6. Java 环境检查与安装
if command -v java &>/dev/null && java -version 2>&1 | grep -q 'version "21'; then
    log_info "Java 21 已安装，跳过。"
else
    log_info "正在安装 OpenJDK 21..."
    apt-get update -qq
    apt-get --fix-broken install -y
    apt-get install -y openjdk-21-jdk
    # 清理旧版本
    apt-get remove -y --purge openjdk-8* || true
    apt-get --fix-broken install -y
fi

# 7. 更新数据库设备信息
# 构造 JSON (使用前文捕获的 DEV_TYPE 和 DEVICE_NAME)
HW_SCAN_CMD="df -H | grep ${DEVICE_NAME} | awk '{print \$5}'"
# 转义 JSON 字符串中的特殊字符
ESCAPED_HW=$(printf '%s' "$HW_SCAN_CMD" | sed 's/\\/\\\\/g; s/"/\\"/g')
JSON_VALUE="{\"devType\":${DEV_TYPE},\"devHWPath\":\"/etc/init.d/cid\",\"devHWSCan\":\"${ESCAPED_HW}\"}"

# SQL 转义（处理单引号：将 ' 替换为 ''）
SQL_VALUE=$(echo "$JSON_VALUE" | sed "s/'/''/g")

log_info "正在更新数据库设备信息..."
# 使用经过双重转义（JSON转义+SQL转义）后的变量 SQL_VALUE
exec_sql "UPDATE public.global_configuration SET value = '${SQL_VALUE}' WHERE name = 'devInfo';"

echo ""
log_info "✅ 所有任务完成！系统已成功更新。"