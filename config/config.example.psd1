# 配置示例。复制为同目录下的 config.psd1 再按需修改（config.psd1 已在 .gitignore 中，不会被提交）。
# 所有项目都是可选的；没有 config.psd1 时，工具会测全部内置区域，网站标题显示"本机"。
@{
    # 网站标题里显示的站点名称，例如 '笔记本-移动宽带'、'公司网络'
    SiteLabel = ''

    # 测速网站端口（只监听本机 localhost）
    DashboardPort = 8765

    # 定时任务（tools\安装定时任务.cmd 读取这里的设置）
    Schedule = @{
        TaskName           = 'CloudLatencyProbe'
        Times              = @('00:00','01:00','02:00','03:00','04:00','05:00','06:00','07:00','08:00','09:00','10:00','11:00',
                               '12:00','13:00','14:00','15:00','16:00','17:00','18:00','19:00','20:00','21:00','22:00','23:00')
        RandomDelayMinutes = 5
        # Interactive = 只在你登录 Windows 时运行（个人电脑推荐，无需管理员）
        # S4U         = 不登录也运行、不保存密码（服务器推荐，需以管理员身份安装）
        LogonType          = 'Interactive'
    }

    # 定时任务 / 命令行不指定 -Regions 时测哪些区域；留空 = 全部内置区域（约 74 个，每次约 6~8 分钟）
    # 区域代码：Oracle 原生代码（ap-tokyo-1）、Azure 加 azure- 前缀、AWS 加 aws- 前缀
    Regions = @()
    # 例：Regions = @('ap-tokyo-1','ap-osaka-1','azure-japaneast','azure-southeastasia','aws-ap-northeast-1','aws-ap-east-1')

    # 对照组：和各区域一起测的你自己的服务器。名称 = 'IP或域名:TCP端口'（端口需对外开放）
    Reference = @{
        # 'MyVPS-Tokyo(对照)' = '203.0.113.10:443'
    }
    # 对照组的位置说明（显示在"位置"列）
    ReferenceNames = @{
        # 'MyVPS-Tokyo(对照)' = '日本东京(我的VPS)'
    }

    # 回程探测：在某区域有你自己的 Linux 服务器时，SSH 上去用 mtr 往回追踪到你的公网 IP。
    # 键 = 区域代码或上面 Reference 里的名称；值 = 'SSH用户名@服务器地址'。服务器需安装 mtr（sudo apt install mtr-tiny）。
    ReturnProbes = @{
        # 'MyVPS-Tokyo(对照)' = 'ubuntu@203.0.113.10'
    }
    # SSH 私钥（可选；不填则用 ssh 默认密钥或 ssh-agent），支持 %USERPROFILE% 等环境变量
    SshKey = ''

    # ipinfo.io 访问令牌（可选；查询量大或被限流时到 ipinfo.io 免费注册获取）
    IpinfoToken = ''
}
