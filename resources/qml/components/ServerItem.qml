// components/ServerItem.qml (优化版 - 显示更多属性)
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 2.15
import JinGo 1.0

ItemDelegate {
    id: serverItem

    property var server: null
    property bool isSelected: false
    property bool isDarkMode: false
    property bool showDetails: true  // 是否显示详细信息

    width: parent.width
    height: showDetails ? 90 : 70

    hoverEnabled: true

    background: Rectangle {
        radius: Theme.radius.md
        color: {
            if (serverItem.isSelected) return Theme.alpha(Theme.colors.primary, 0.15)
            if (serverItem.hovered) return isDarkMode ? "#353535" : "#F8F8F8"
            return Theme.colors.surface
        }
        border.color: serverItem.isSelected ? Theme.colors.primary :
                     (isDarkMode ? "#3A3A3A" : "#E0E0E0")
        border.width: serverItem.isSelected ? 2 : 1

        Behavior on color {
            ColorAnimation { duration: Theme.duration.normal }
        }

        Behavior on border.color {
            ColorAnimation { duration: Theme.duration.normal }
        }

        // 选中时的左侧指示条
        Rectangle {
            visible: serverItem.isSelected
            width: 4
            height: parent.height - 16
            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            radius: 2
            color: Theme.colors.primary
        }
    }

    contentItem: RowLayout {
        anchors.fill: parent
        anchors.margins: Theme.spacing.md
        spacing: Theme.spacing.sm

        // 国旗/图标 - 垂直居中
        FlagIcon {
            Layout.preferredWidth: 48
            Layout.preferredHeight: 48
            Layout.alignment: Qt.AlignVCenter
            size: 48
            countryCode: server ? (server.countryCode || "") : ""
        }

        // 服务器信息 - 左对齐
        ColumnLayout {
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: Theme.spacing.xxs

            // 第一行：服务器名称 + 协议标签
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.xs

                Label {
                    text: server ? server.name : qsTr("UnknownServers")
                    font.pixelSize: Theme.typography.body1
                    font.weight: Theme.typography.weightBold
                    color: serverItem.isSelected ? Theme.colors.primary :
                           Theme.colors.textPrimary
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }

                // 协议标签
                Rectangle {
                    visible: server && server.protocol
                    Layout.preferredHeight: 20
                    Layout.preferredWidth: protocolLabel.implicitWidth + 12
                    radius: 10
                    color: getProtocolColor()

                    Label {
                        id: protocolLabel
                        anchors.centerIn: parent
                        text: server ? server.protocol.toUpperCase() : ""
                        font.pixelSize: Theme.typography.small
                        font.weight: Theme.typography.weightBold
                        color: "white"
                    }
                }
            }

            // 第二行：位置信息
            RowLayout {
                Layout.fillWidth: true
                spacing: Theme.spacing.xs

                Label {
                    text: "📍"
                    font.pixelSize: Theme.typography.caption
                }

                Label {
                    text: server ? server.location : ""
                    font.pixelSize: Theme.typography.body2
                    color: serverItem.isSelected ? Theme.colors.primary :
                           Theme.colors.textSecondary
                    elide: Text.ElideRight
                    Layout.fillWidth: true
                }
            }

            // 第三行：附加信息（仅在显示详情时）
            RowLayout {
                visible: showDetails
                Layout.fillWidth: true
                spacing: Theme.spacing.md

                // 负载状态（示例）
                RowLayout {
                    spacing: Theme.spacing.xxs
                    visible: server && server.load !== undefined

                    IconSymbol {
                        icon: "speed"
                        size: Theme.typography.caption
                        color: Theme.colors.textSecondary
                    }

                    Label {
                        text: server ? qsTr("Load %1%").arg(server.load || 0) : ""
                        font.pixelSize: Theme.typography.caption
                        color: Theme.colors.textTertiary
                    }
                }

                // 在线人数（示例）
                RowLayout {
                    spacing: Theme.spacing.xxs
                    visible: server && server.onlineUsers !== undefined

                    Label {
                        text: "👥"
                        font.pixelSize: Theme.typography.caption
                    }

                    Label {
                        text: server ? String(server.onlineUsers || 0) : ""
                        font.pixelSize: Theme.typography.caption
                        color: Theme.colors.textTertiary
                    }
                }

                // 最后测试时间
                RowLayout {
                    spacing: Theme.spacing.xxs
                    visible: server && server.lastTested

                    Label {
                        text: "🕐"
                        font.pixelSize: Theme.typography.caption
                    }

                    Label {
                        text: server ? getLastTestedText() : ""
                        font.pixelSize: Theme.typography.caption
                        color: Theme.colors.textTertiary
                    }
                }

                // 吞吐量速度显示
                RowLayout {
                    spacing: Theme.spacing.xxs
                    visible: getSpeedResultText() !== ""

                    IconSymbol {
                        icon: "speed"
                        size: Theme.typography.caption
                        color: Theme.colors.success
                    }

                    Label {
                        text: getSpeedResultText()
                        font.pixelSize: Theme.typography.caption
                        font.weight: Theme.typography.weightBold
                        color: Theme.colors.success
                    }
                }

                Item { Layout.fillWidth: true }
            }
        }

        // 延迟显示 - 垂直居中，右对齐
        ColumnLayout {
            Layout.alignment: Qt.AlignVCenter | Qt.AlignRight
            spacing: Theme.spacing.xxs

            // 延迟数值
            Rectangle {
                Layout.preferredWidth: 80
                Layout.preferredHeight: 32
                Layout.alignment: Qt.AlignRight
                radius: 16
                color: getLatencyColor()

                RowLayout {
                    anchors.centerIn: parent
                    spacing: Theme.spacing.xxs

                    Rectangle {
                        width: 8
                        height: 8
                        radius: 4
                        color: "white"

                        // 连接中的闪烁动画
                        SequentialAnimation on opacity {
                            running: server && server.latency > 0
                            loops: Animation.Infinite
                            NumberAnimation { from: 1.0; to: 0.3; duration: 800 }
                            NumberAnimation { from: 0.3; to: 1.0; duration: 800 }
                        }
                    }

                    Label {
                        text: getLatencyText()
                        font.pixelSize: Theme.typography.body2
                        font.weight: Theme.typography.weightBold
                        color: "white"
                    }
                }
            }

            // 延迟等级文本
            Label {
                visible: showDetails && server && server.latency > 0
                text: getLatencyLevelText()
                font.pixelSize: Theme.typography.tiny
                color: Theme.colors.textTertiary
                horizontalAlignment: Text.AlignHCenter
                Layout.alignment: Qt.AlignHCenter
            }
        }

        // 测速按钮
        Button {
            id: testButton
            Layout.preferredWidth: 36
            Layout.preferredHeight: 36
            Layout.alignment: Qt.AlignVCenter

            property bool isTesting: false

            background: Rectangle {
                radius: 18
                color: {
                    if (testButton.pressed) return Theme.alpha(Theme.colors.primary, 0.3)
                    if (testButton.hovered) return Theme.alpha(Theme.colors.primary, 0.2)
                    return Theme.alpha(Theme.colors.primary, 0.1)
                }
                border.color: Theme.alpha(Theme.colors.primary, 0.3)
                border.width: 1

                Behavior on color {
                    ColorAnimation { duration: Theme.duration.fast }
                }
            }

            contentItem: IconSymbol {
                icon: testButton.isTesting ? "refresh" : "speed"
                size: 18
                color: Theme.colors.textPrimary

                // 测试中的旋转动画
                RotationAnimation on rotation {
                    running: testButton.isTesting
                    loops: Animation.Infinite
                    from: 0
                    to: 360
                    duration: 1000
                }
            }

            ToolTip.visible: hovered
            ToolTip.text: testButton.isTesting ? qsTr("Testing...") : qsTr("Test Speed")

            onClicked: {
                if (!server || isTesting) return

                // 查找 ServerListPage 并调用其 startThroughputTest 函数
                var page = null
                var obj = parent
                while (obj !== null) {
                    if (obj.hasOwnProperty("startThroughputTest") && typeof obj.startThroughputTest === "function") {
                        page = obj
                        break
                    }
                    obj = obj.parent
                }

                if (page) {
                    isTesting = true
                    // 调用页面级函数，会显示弹窗
                    page.startThroughputTest(server.id, server.name || server.address || "")
                } else {
                    // 备用：直接调用 viewModel
                    var viewModel = null
                    obj = parent
                    while (obj !== null) {
                        if (obj.hasOwnProperty("serverListViewModel")) {
                            viewModel = obj.serverListViewModel
                            break
                        }
                        obj = obj.parent
                    }
                    if (viewModel) {
                        isTesting = true
                        viewModel.testServerThroughput(server.id)
                    }
                }
            }

            Connections {
                target: {
                    // 获取serverListViewModel
                    var viewModel = null
                    var obj = testButton.parent
                    while (obj !== null) {
                        if (obj.hasOwnProperty("serverListViewModel")) {
                            viewModel = obj.serverListViewModel
                            break
                        }
                        obj = obj.parent
                    }
                    return viewModel
                }

                function onServerThroughputTestCompleted(testedServer, speedMbps) {
                    if (server && testedServer && server.id === testedServer.id) {
                        testButton.isTesting = false
                    }
                }
            }
        }

        // 选中指示器
        Rectangle {
            Layout.preferredWidth: 24
            Layout.preferredHeight: 24
            Layout.alignment: Qt.AlignVCenter
            radius: 12
            border.color: serverItem.isSelected ? Theme.colors.primary :
                         Theme.colors.border
            border.width: 2
            color: "transparent"

            Rectangle {
                visible: serverItem.isSelected
                width: 12
                height: 12
                anchors.centerIn: parent
                radius: 6
                color: Theme.colors.primary

                // 选中时的缩放动画
                scale: serverItem.isSelected ? 1.0 : 0
                Behavior on scale {
                    NumberAnimation {
                        duration: Theme.duration.normal
                        easing.type: Theme.easing.emphasized
                    }
                }
            }
        }
    }

    // 辅助函数
    function getLatencyText() {
        if (!server) return "--"
        var latency = server.latency
        if (latency === 0) return qsTr("Timeout")
        if (latency < 0) return qsTr("Not Tested")
        return latency + "ms"
    }

    function getLatencyColor() {
        if (!server) return Theme.colors.textDisabled
        var latency = server.latency
        if (latency === 0) return Theme.colors.error       // 超时 - 红色
        if (latency < 0) return isDarkMode ? "#3A3A3A" : "#E0E0E0"  // 未测试
        if (latency < 50) return Theme.colors.success      // 优秀 - 绿色
        if (latency < 100) return "#4CAF50"                // 良好 - 浅绿
        if (latency < 200) return Theme.colors.warning     // 一般 - 橙色
        return Theme.colors.error                          // 较差 - 红色
    }

    function getLatencyLevelText() {
        if (!server) return ""
        var latency = server.latency
        if (latency <= 0) return ""
        if (latency < 50) return qsTr("Excellent")
        if (latency < 100) return qsTr("Good")
        if (latency < 200) return qsTr("General")
        return qsTr("Poor")
    }

    function getProtocolColor() {
        if (!server) return Theme.colors.secondary
        // 所有协议统一使用主题定义的协议标签颜色
        return Theme.colors.protocolBadge
    }

    function getLastTestedText() {
        if (!server || !server.lastTested) return ""

        var now = new Date()
        var tested = server.lastTested
        var diff = (now - tested) / 1000  // 秒

        if (diff < 60) return qsTr("Just now")
        if (diff < 3600) return qsTr("%1 minutes ago").arg(Math.floor(diff / 60))
        if (diff < 86400) return qsTr("%1 hours ago").arg(Math.floor(diff / 3600))
        return qsTr("%1 days ago").arg(Math.floor(diff / 86400))
    }

    // 获取吞吐量测试结果文本
    function getSpeedResultText() {
        if (!server) return ""

        // 获取serverListViewModel
        var viewModel = null
        var obj = serverItem.parent
        while (obj !== null) {
            if (obj.hasOwnProperty("serverListViewModel")) {
                viewModel = obj.serverListViewModel
                break
            }
            obj = obj.parent
        }

        if (!viewModel) return ""

        var result = viewModel.getSpeedTestResult(server.id)
        if (result && result.speed) {
            return result.speed
        }
        return ""
    }

    // 按压效果
    scale: pressed ? 0.98 : 1.0
    Behavior on scale {
        NumberAnimation {
            duration: Theme.duration.fast
            easing.type: Theme.easing.standard
        }
    }
}