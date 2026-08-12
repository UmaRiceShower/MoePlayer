import QtQuick
import QtQuick.Controls
import MoePlayer.Core
import "qrc:/qml/theme"

//! 服务器管理页:添加/删除/修改要连接的 Emby 服务器(账号)。
//! 列表选中账号后表单预填可修改元数据;新增时需填密码完成登录校验;
//! 换密码请删除后重新添加。打开方式 Ctrl+O(Main 注册快捷键)。
Item {
    id: root

    signal backRequested()

    // 正在编辑的账号 id,空表示新增。
    property string editingId: ""
    // 表单字段。
    property string fName: ""
    property string fServer: ""
    property string fUser: ""
    property string fPassword: ""
    property string statusText: ""

    function clearForm() {
        root.editingId = ""
        root.fName = ""
        root.fServer = ""
        root.fUser = ""
        root.fPassword = ""
    }

    function saveForm() {
        if (root.fServer.trim() === "" || root.fUser.trim() === "")
            return
        if (root.editingId !== "") {
            AccountManager.updateAccount(root.editingId, root.fName, root.fServer, root.fUser)
            root.statusText = "已保存"
        } else {
            if (root.fPassword === "") {
                root.statusText = "新增需要填写密码"
                return
            }
            const started = AccountManager.addAccount(root.fName, root.fServer,
                                                      root.fUser, root.fPassword, true)
            if (!started)
                root.statusText = "参数不完整"
            else
                root.statusText = "正在登录…"
        }
    }

    Column {
        anchors.fill: parent
        spacing: 16
        padding: 24

        Row {
            spacing: 12
            Button {
                text: "← 返回"
                onClicked: root.backRequested()
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "服务器管理（Ctrl+O）"
                color: Theme.textPrimary
                font.pixelSize: 24
                font.bold: true
            }
        }

        Row {
            spacing: 24

            // 左:账号列表
            Rectangle {
                width: 420
                height: 420
                color: Theme.surface
                radius: 8

                ListView {
                    anchors.fill: parent
                    anchors.margins: 8
                    clip: true
                    model: AccountManager.accounts
                    delegate: Rectangle {
                        width: parent.width
                        height: 64
                        radius: 6
                        // 失效账号(重登失败)标红底;选中用强调色。
                        color: ListView.isCurrentItem ? Theme.accent
                               : (modelData.tokenValid === false ? Theme.invalidBg : "transparent")
                        border.width: ListView.isCurrentItem ? 0
                                   : (modelData.tokenValid === false ? 2 : 1)
                        border.color: modelData.tokenValid === false ? Theme.danger : Theme.bg

                        Column {
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            spacing: 2
                            Text {
                                // 未填名称时显示用户名(首页聚合前缀此时用 ServerName)。
                                text: (modelData.name !== "" ? modelData.name : modelData.userName)
                                      + (modelData.tokenValid === false ? "  [凭据失效]" : "")
                                      + (modelData.id === AccountManager.activeAccountId
                                         ? "  [当前]" : "")
                                color: ListView.isCurrentItem ? "white" : Theme.textPrimary
                                font.bold: true
                            }
                            Text {
                                text: modelData.userName + " · " + modelData.serverUrl
                                color: ListView.isCurrentItem ? Theme.textSelected : Theme.textMuted
                                font.pixelSize: 12
                                elide: Text.ElideRight
                                width: 330
                            }
                        }
                        // 排序按钮:账号顺序即首页聚合顺序(Home 在 accountsChanged 时重拉)。
                        // z 置顶:整行选中 MouseArea 声明在其后,默认覆盖并拦截按钮点击。
                        Row {
                            z: 2
                            anchors.verticalCenter: parent.verticalCenter
                            anchors.right: parent.right
                            anchors.rightMargin: 8
                            spacing: 4
                            Button {
                                width: 28
                                height: 28
                                text: "↑"
                                padding: 0
                                onClicked: AccountManager.moveAccountUp(modelData.id)
                            }
                            Button {
                                width: 28
                                height: 28
                                text: "↓"
                                padding: 0
                                onClicked: AccountManager.moveAccountDown(modelData.id)
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            onClicked: {
                                listView.currentIndex = index
                                root.editingId = modelData.id
                                root.fName = modelData.name
                                root.fServer = modelData.serverUrl
                                root.fUser = modelData.userName
                                root.fPassword = ""
                                root.statusText = ""
                            }
                        }
                    }
                    id: listView
                }

                Button {
                    anchors.bottom: parent.bottom
                    anchors.right: parent.right
                    anchors.margins: 10
                    text: "新建服务器"
                    onClicked: {
                        listView.currentIndex = -1
                        root.clearForm()
                        root.statusText = ""
                    }
                }
            }

            // 右:编辑表单
            Column {
                width: 380
                spacing: 10

                Text {
                    text: root.editingId === "" ? "添加服务器" : "修改服务器"
                    color: Theme.textPrimary
                    font.pixelSize: 16
                    font.bold: true
                }

                Text { text: "名称"; color: Theme.textMuted; font.pixelSize: 13 }
                TextField {
                    width: 380
                    placeholderText: "如: 家庭服务器"
                    text: root.fName
                    onEditingFinished: root.fName = text
                }

                Text { text: "服务器地址"; color: Theme.textMuted; font.pixelSize: 13 }
                TextField {
                    width: 380
                    placeholderText: "http://host:8096"
                    text: root.fServer
                    onEditingFinished: root.fServer = text
                }

                Text { text: "用户名"; color: Theme.textMuted; font.pixelSize: 13 }
                TextField {
                    width: 380
                    text: root.fUser
                    onEditingFinished: root.fUser = text
                }

                Text {
                    text: root.editingId === "" ? "密码（仅新增时登录校验用）"
                                                : "密码（换密码请删除后重新添加）"
                    color: Theme.textMuted
                    font.pixelSize: 13
                }
                TextField {
                    width: 380
                    echoMode: TextInput.Password
                    text: root.fPassword
                    onEditingFinished: root.fPassword = text
                }

                Row {
                    spacing: 10
                    Button {
                        text: root.editingId === "" ? "添加并登录" : "保存修改"
                        enabled: root.fServer.trim() !== "" && root.fUser.trim() !== ""
                        onClicked: root.saveForm()
                    }
                    Button {
                        text: "删除"
                        enabled: root.editingId !== ""
                        onClicked: {
                            AccountManager.removeAccount(root.editingId)
                            root.clearForm()
                            root.statusText = "已删除"
                        }
                    }
                }

                Text {
                    text: root.statusText
                    color: root.statusText.indexOf("失败") >= 0 || root.statusText.indexOf("密码") >= 0
                          ? Theme.danger : Theme.textMuted
                }
            }
        }
    }

    Connections {
        target: AccountManager
        function onAccountLoginFinished(ok, message) {
            root.statusText = ok ? "添加成功" : "添加失败：" + message
        }
        function onAccountsChanged() {
            // 列表变化时若编辑项被删/改,重置表单状态(保留用户输入由新建按钮负责)。
        }
    }
}
