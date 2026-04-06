// pages/ConnectionPage.qml (完美优化版 - 无 GraphicalEffects 依赖)
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 2.15
import QtQuick.Window 2.15
import JinGo 1.0

Rectangle {
    id: connectionPage
    readonly property var mainWindow: Qt.application.topLevelWindow || null
    color: Theme.colors.pageBackground

    // 状态绑定
    readonly property bool isDarkMode: mainWindow ? mainWindow.isDarkMode : false

    // 使用本地属性来存储连接状态，确保UI能正确更新
    property bool isConnected: false
    property bool isConnecting: false
    property bool isDisconnecting: false

    // 修改为普通属性，避免在初始化时访问authManager
    property bool isAuthenticated: false

    // 连接状态消息（使用 property + signal 方式）
    property string connectionState: qsTr("Not Connected")

    // 服务器选择对话框
    ServerSelectDialog {
        id: serverSelectDialog
        parent: Overlay.overlay
        anchors.centerIn: parent
        isDarkMode: connectionPage.isDarkMode
        selectedServer: connectionPage.currentServer

        onServerSelected: function(server) {
            if (!server) {
                return
            }
            if (!server.id) {
                return
            }
            if (!vpnManager) {
                return
            }

            try {
                vpnManager.selectServer(server)
            } catch (error) {
            }
        }
    }

    // 服务器信息 - 使用手动更新而非自动绑定，避免访问已删除对象
    property var currentServer: null

    // 安全获取当前服务器的函数（仅用于连接按钮点击）
    function getCurrentServer() {
        try {
            if (typeof vpnManager !== 'undefined' && vpnManager) {
                return vpnManager.currentServer || null
            }
        } catch (e) {
        }
        return null
    }

    // 初始化时获取状态消息（延迟执行）
    Timer {
        id: stateMessageTimer
        interval: 100
        running: false  // 不自动启动，等待Component.onCompleted后手动启动
        repeat: false
        onTriggered: {
            try {
                if (vpnManager && typeof vpnManager.stateMessage === 'function') {
                    connectionState = vpnManager.stateMessage()
                }
            } catch (e) {
            }
        }
    }

    // 更新流量统计（实时更新，由statsUpdated信号或定时器触发）
    // 使用connectionViewModel获取数据（Android平台直接从SuperRay获取TUN流量统计）
    function updateTrafficStats() {
        if (!connectionViewModel) {
            return
        }

        var uploadBytes = connectionViewModel.uploadBytes || 0
        var downloadBytes = connectionViewModel.downloadBytes || 0

        uploadCard.uploadText = FormatUtils.formatBytes(uploadBytes)
        downloadCard.downloadText = FormatUtils.formatBytes(downloadBytes)
    }

    property string serverName: qsTr("No Server Selected")
    property string serverFlag: "🌍"
    property string serverCountryCode: ""
    property string serverProtocol: ""
    property int serverLatency: -1

    // 安全更新服务器信息
    function updateServerInfo() {
        try {
            if (vpnManager && typeof vpnManager.currentServer !== 'undefined') {
                var server = vpnManager.currentServer
                if (server && typeof server === 'object') {
                    currentServer = server

                    // 更新服务器名称
                    if (typeof server.name !== 'undefined' && server.name !== null) {
                        serverName = String(server.name)
                    } else {
                        serverName = qsTr("No Server Selected")
                    }

                    // 更新国旗
                    if (typeof server.countryFlag !== 'undefined' && server.countryFlag !== null) {
                        serverFlag = String(server.countryFlag)
                    } else {
                        serverFlag = "🌍"
                    }
                    // 更新国家代码
                    if (typeof server.countryCode !== 'undefined' && server.countryCode !== null) {
                        serverCountryCode = String(server.countryCode)
                    } else {
                        serverCountryCode = ""
                    }

                    // 更新协议
                    if (typeof server.protocol !== 'undefined' && server.protocol !== null) {
                        serverProtocol = String(server.protocol).toUpperCase()
                    } else {
                        serverProtocol = ""
                    }

                    // 更新延迟
                    if (typeof server.latency !== 'undefined' && server.latency !== null) {
                        serverLatency = server.latency
                    } else {
                        serverLatency = -1
                    }

                    return
                }
            }
        } catch (e) {
        }

        // 重置为默认值
        currentServer = null
        serverName = qsTr("No Server Selected")
        serverFlag = "🌍"
        serverCountryCode = ""
        serverProtocol = ""
        serverLatency = -1
    }
    readonly property string connectButtonText: {
        if (isConnecting) return qsTr("Connecting...")
        if (isDisconnecting) return qsTr("Disconnecting...")
        if (isConnected) return qsTr("Connected")
        return qsTr("Not Connected")
    }
    readonly property color mainColor: {
        if (isConnecting || isDisconnecting) return "#FFA500"  // 橙色：连接中
        if (isConnected) return "#4CAF50"  // 绿色：已连接
        return "#007BFF"  // 蓝色：未连接
    }

    // 连接时长
    property int connectedSeconds: 0
    property string connectedDurationText: "00:00:00"

    // 更新连接状态的函数
    function updateConnectionState() {
        try {
            if (vpnManager && typeof vpnManager.isConnected !== 'undefined') {
                var oldConnected = isConnected
                var oldConnecting = isConnecting
                var oldDisconnecting = isDisconnecting

                isConnected = vpnManager.isConnected || false
                isConnecting = vpnManager.isConnecting || false
                isDisconnecting = vpnManager.isDisconnecting || false

                // 【关键修复】同步更新状态文字
                if (typeof vpnManager.stateMessage === 'function') {
                    connectionState = vpnManager.stateMessage()
                }
            } else {
                isConnected = false
                isConnecting = false
                isDisconnecting = false
                connectionState = qsTr("Not Connected")
            }
        } catch (error) {
            isConnected = false
            isConnecting = false
            isDisconnecting = false
            connectionState = qsTr("Not Connected")
        }
    }

    // 监听页面可见性变化，只在页面显示时才初始化
    onVisibleChanged: {
        if (visible) {
            // 使用 Timer 延迟初始化，确保页面完全加载
            connectionInitTimer.start()
        }
    }

    // 组件完成时的初始化
    Component.onCompleted: {
        // 安全地更新isAuthenticated
        try {
            if (typeof authManager !== 'undefined' && authManager && typeof authManager.isAuthenticated !== 'undefined') {
                isAuthenticated = authManager.isAuthenticated || false
            }
        } catch (e) {
            isAuthenticated = false
        }

        // 启动状态消息定时器
        stateMessageTimer.start()

        // 立即触发初始化（页面创建时可能已经是 visible 状态，onVisibleChanged 不会触发）
        connectionInitTimer.start()
    }

    // 初始化定时器 - 延迟执行以确保页面完全就绪
    Timer {
        id: connectionInitTimer
        interval: 100  // 延迟100毫秒
        running: false
        repeat: false
        onTriggered: {
            updateConnectionState()
            updateServerInfo()  // 【修复】加载已选择的服务器信息
            updateTrafficStats()
        }
    }

    // 连接时长定时器
    Timer {
        id: durationTimer
        interval: 1000
        running: isConnected
        repeat: true
        onTriggered: {
            try {
                if (vpnManager && typeof vpnManager !== 'undefined' && isConnected &&
                    typeof vpnManager.connectedDuration !== 'undefined') {
                    connectedSeconds = Number(vpnManager.connectedDuration) || 0
                    var hours = Math.floor(connectedSeconds / 3600)
                    var minutes = Math.floor((connectedSeconds % 3600) / 60)
                    var seconds = connectedSeconds % 60
                    connectedDurationText = Qt.formatTime(new Date(0, 0, 0, hours, minutes, seconds), "hh:mm:ss")
                } else {
                    connectedSeconds = 0
                    connectedDurationText = "00:00:00"
                }
            } catch (e) {
                connectedSeconds = 0
                connectedDurationText = "00:00:00"
            }
        }
    }

    // 监听认证状态变化
    Connections {
        target: authManager

        function onAuthenticationChanged() {
            try {
                if (typeof authManager !== 'undefined' && authManager) {
                    isAuthenticated = authManager.isAuthenticated || false
                }
            } catch (e) {
                // 忽略初始化错误
            }
        }

        function onLoginSucceeded() {
            isAuthenticated = true
        }

        function onLogoutCompleted() {
            isAuthenticated = false
        }
    }

    // 监听连接状态变化
    Connections {
        target: vpnManager

        // 监听当前服务器变化
        function onCurrentServerChanged() {
            updateServerInfo()
        }

        // 监听状态变化信号，手动更新连接状态
        function onStateChanged(newState) {
            updateConnectionState()
            updateServerInfo()
        }

        function onConnected() {
            connectedSeconds = 0
            // 确保所有状态都同步更新
            updateConnectionState()
            updateServerInfo()
            updateTrafficStats()  // 初始化流量统计显示
        }

        function onDisconnected() {
            connectedSeconds = 0
            connectedDurationText = "00:00:00"
            // 确保所有状态都同步更新
            updateConnectionState()
            updateServerInfo()
        }

        function onConnectFailed(reason) {
            // 连接失败时也要更新状态
            updateConnectionState()
            updateServerInfo()
            // 可以在这里显示错误提示
        }

        function onStateMessageChanged() {
            if (vpnManager && typeof vpnManager.stateMessage === 'function') {
                connectionState = vpnManager.stateMessage()
            }
        }

        // 监听IP和延时检测完成信号
        function onConnectionInfoUpdated() {
            // IP和延时更新完成
        }

        // 监听流量统计更新信号
        function onStatsUpdated(uploadBytes, downloadBytes) {
            updateTrafficStats()
        }
    }

    // 背景装饰 (性能优化版 - 仅在连接时显示，减少动画)
    Item {
        anchors.fill: parent
        opacity: 0.03
        visible: isConnected  // 仅在连接时显示，减少性能消耗

        // 简化为单个装饰元素
        Rectangle {
            width: parent.width * 0.6
            height: parent.width * 0.6
            radius: width / 2
            color: mainColor
            anchors.centerIn: parent
            opacity: 0.15

            // 简化动画：更长的duration，减少CPU占用
            SequentialAnimation on scale {
                running: isConnected && connectionPage.visible
                loops: Animation.Infinite
                NumberAnimation { from: 1.0; to: 1.2; duration: 8000; easing.type: Easing.InOutQuad }
                NumberAnimation { from: 1.2; to: 1.0; duration: 8000; easing.type: Easing.InOutQuad }
            }
        }
    }

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

        ColumnLayout {
            width: parent.width
            spacing: 0

            Item { Layout.preferredHeight: 40 }

            // 主连接区域
            ColumnLayout {
                Layout.alignment: Qt.AlignHCenter
                Layout.fillWidth: true
                Layout.leftMargin: (mainWindow && mainWindow.isDesktop) ? 40 : 20
                Layout.rightMargin: (mainWindow && mainWindow.isDesktop) ? 40 : 20
                spacing: 20

                // 第一行：连接按钮和服务器信息
                // 移动端使用垂直布局，桌面端使用水平布局
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: (mainWindow && mainWindow.isMobile) ? 16 : 0
                    visible: mainWindow && mainWindow.isMobile

                    // 移动端：连接按钮居中
                    Item {
                        Layout.alignment: Qt.AlignHCenter
                        Layout.preferredWidth: 120
                        Layout.preferredHeight: 120

                        // 外圈动画
                        Rectangle {
                            anchors.centerIn: parent
                            width: isConnected ? 136 : 120
                            height: isConnected ? 136 : 120
                            radius: width / 2
                            color: "transparent"
                            border.color: mainColor
                            border.width: 2
                            opacity: isConnecting ? 0.6 : 0.3

                            Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                            Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                            Behavior on opacity { NumberAnimation { duration: 300 } }

                            RotationAnimation on rotation {
                                running: isConnecting && connectionPage.visible
                                from: 0; to: 360; duration: 2000; loops: Animation.Infinite
                            }

                            SequentialAnimation on scale {
                                running: isConnected && !isConnecting && connectionPage.visible
                                loops: Animation.Infinite
                                NumberAnimation { from: 1.0; to: 1.1; duration: 1500; easing.type: Easing.InOutQuad }
                                NumberAnimation { from: 1.1; to: 1.0; duration: 1500; easing.type: Easing.InOutQuad }
                            }
                        }

                        Rectangle {
                            anchors.centerIn: parent
                            width: 100; height: 100; radius: 50
                            color: mainColor; opacity: 0.1
                        }

                        Rectangle {
                            anchors.centerIn: parent
                            width: 80; height: 80; radius: 40
                            gradient: Gradient {
                                GradientStop { position: 0.0; color: mainColor }
                                GradientStop { position: 1.0; color: Qt.darker(mainColor, 1.2) }
                            }

                            Rectangle {
                                anchors.centerIn: parent
                                width: parent.width + 4; height: parent.height + 4
                                radius: width / 2; color: mainColor; opacity: 0.2; z: -1
                            }

                            scale: mobileConnectBtnArea.pressed ? 0.95 : 1.0
                            Behavior on scale { NumberAnimation { duration: 100; easing.type: Easing.OutCubic } }

                            Image {
                                source: isConnected ? "qrc:/images/connect.png" : "qrc:/images/disconnect.png"
                                width: 32; height: 32; anchors.centerIn: parent
                                smooth: true; antialiasing: true
                            }

                            MouseArea {
                                id: mobileConnectBtnArea
                                anchors.fill: parent
                                enabled: isAuthenticated && !isConnecting && !isDisconnecting && (!serverListViewModel || !serverListViewModel.isRefreshingServers)
                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ForbiddenCursor
                                onClicked: {
                                    if (!vpnManager) return
                                    if (!isConnected) {
                                        var serverToConnect = getCurrentServer()
                                        if (!serverToConnect) { serverSelectDialog.open(); return }
                                        if (!serverToConnect.id) return
                                        try { vpnManager.connecting(serverToConnect) } catch (e) {}
                                    } else {
                                        try { vpnManager.disconnect() } catch (e) {}
                                    }
                                }
                            }
                        }
                    }

                    // 移动端：服务器信息卡片
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 100
                        radius: 16
                        color: Theme.colors.surface
                        border.color: isDarkMode ? "#2A2A2A" : "#E8E8E8"
                        border.width: 1

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 16
                            spacing: 8

                            Label {
                                text: connectButtonText
                                font.pixelSize: 18
                                font.bold: true
                                color: mainColor
                                Layout.alignment: Qt.AlignLeft
                            }

                            Label {
                                text: isConnected && vpnManager && vpnManager.ipInfo ? vpnManager.ipInfo : connectionState
                                font.pixelSize: 11
                                color: isDarkMode ? "#999999" : "#666666"
                                visible: text !== ""
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }

                            Rectangle { Layout.fillWidth: true; height: 1; color: isDarkMode ? "#2A2A2A" : "#E8E8E8" }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 10

                                FlagIcon {
                                    size: 20
                                    countryCode: serverCountryCode
                                }
                                Label {
                                    text: serverName
                                    font.pixelSize: 13
                                    font.bold: true
                                    color: Theme.colors.textPrimary
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }
                                Label {
                                    text: "›"
                                    font.pixelSize: 18
                                    color: isDarkMode ? "#666666" : "#CCCCCC"
                                }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: serverSelectDialog.open()
                        }
                    }
                }

                // 桌面端布局：水平排列
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 20
                    visible: !(mainWindow && mainWindow.isMobile)

                    // 连接按钮
                    Item {
                        Layout.preferredWidth: 140
                        Layout.preferredHeight: 140

                        // 外圈动画
                        Rectangle {
                            anchors.centerIn: parent
                            width: isConnected ? 156 : 140
                            height: isConnected ? 156 : 140
                            radius: width / 2
                            color: "transparent"
                            border.color: mainColor
                            border.width: 2
                            opacity: isConnecting ? 0.6 : 0.3

                            Behavior on width {
                                NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
                            }
                            Behavior on height {
                                NumberAnimation { duration: 300; easing.type: Easing.OutCubic }
                            }
                            Behavior on opacity {
                                NumberAnimation { duration: 300 }
                            }

                            // 连接中旋转动画
                            RotationAnimation on rotation {
                                running: isConnecting && connectionPage.visible
                                from: 0
                                to: 360
                                duration: 2000
                                loops: Animation.Infinite
                            }

                            // 已连接脉冲动画
                            SequentialAnimation on scale {
                                running: isConnected && !isConnecting && connectionPage.visible
                                loops: Animation.Infinite
                                NumberAnimation { from: 1.0; to: 1.1; duration: 1500; easing.type: Easing.InOutQuad }
                                NumberAnimation { from: 1.1; to: 1.0; duration: 1500; easing.type: Easing.InOutQuad }
                            }
                        }

                        // 中圈
                        Rectangle {
                            anchors.centerIn: parent
                            width: 120
                            height: 120
                            radius: width / 2
                            color: mainColor
                            opacity: 0.1
                        }

                        // 连接按钮主体
                        Rectangle {
                            id: connectButton
                            anchors.centerIn: parent
                            width: 100
                            height: 100
                            radius: width / 2

                            gradient: Gradient {
                                GradientStop { position: 0.0; color: mainColor }
                                GradientStop { position: 1.0; color: Qt.darker(mainColor, 1.2) }
                            }

                            // 伪阴影效果
                            Rectangle {
                                anchors.centerIn: parent
                                width: parent.width + 6
                                height: parent.height + 6
                                radius: width / 2
                                color: mainColor
                                opacity: 0.2
                                z: -1
                            }

                            scale: connectButtonMouseArea.pressed ? 0.95 : 1.0
                            Behavior on scale {
                                NumberAnimation { duration: 100; easing.type: Easing.OutCubic }
                            }

                            // 连接中脉冲动画
                            SequentialAnimation on opacity {
                                running: isConnecting && connectionPage.visible
                                loops: Animation.Infinite
                                NumberAnimation { from: 1.0; to: 0.7; duration: 800; easing.type: Easing.InOutQuad }
                                NumberAnimation { from: 0.7; to: 1.0; duration: 800; easing.type: Easing.InOutQuad }
                            }

                            // 按钮图标
                            Image {
                                source: isConnected ?
                                    "qrc:/images/connect.png" : "qrc:/images/disconnect.png"
                                width: 40
                                height: 40
                                anchors.centerIn: parent
                                smooth: true
                                antialiasing: true
                            }

                            MouseArea {
                                id: connectButtonMouseArea
                                anchors.fill: parent
                                enabled: isAuthenticated && !isConnecting && !isDisconnecting && (!subscriptionManager || !subscriptionManager.isRefreshingServers)
                                cursorShape: enabled ? Qt.PointingHandCursor : Qt.ForbiddenCursor

                                onClicked: {
                                    if (!vpnManager) {
                                        return
                                    }

                                    if (!isConnected) {
                                        // 未连接状态 → 尝试连接
                                        var serverToConnect = getCurrentServer()

                                        if (!serverToConnect) {
                                            serverSelectDialog.open()
                                            return
                                        }

                                        if (!serverToConnect.id) {
                                            return
                                        }

                                        if (typeof serverToConnect.isValid === 'function' && !serverToConnect.isValid()) {
                                            return
                                        }

                                        try {
                                            vpnManager.connecting(serverToConnect)
                                        } catch (error) {
                                        }
                                    } else {
                                        // 已连接状态 → 断开连接
                                        try {
                                            vpnManager.disconnect()
                                        } catch (error) {
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // 服务器信息卡片（在同一行）
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 140
                        radius: 20
                        color: Theme.colors.surface
                        border.color: isDarkMode ? "#2A2A2A" : "#E8E8E8"
                        border.width: 1

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.margins: 20
                            spacing: 12

                            // 连接状态
                            Label {
                                text: connectButtonText
                                font.pixelSize: 20
                                font.bold: true
                                color: mainColor
                                Layout.alignment: Qt.AlignLeft

                                Behavior on color {
                                    ColorAnimation { duration: 300 }
                                }
                            }

                            // 连接状态详细说明 / IP信息
                            Label {
                                text: {
                                    // 已连接时显示 IP 信息
                                    if (isConnected && vpnManager && vpnManager.ipInfo) {
                                        return vpnManager.ipInfo
                                    }
                                    // 连接中/断开中显示状态信息
                                    return connectionState
                                }
                                font.pixelSize: 11
                                color: isDarkMode ? "#999999" : "#666666"
                                Layout.alignment: Qt.AlignLeft
                                visible: text !== ""
                                elide: Text.ElideRight
                                Layout.fillWidth: true
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                height: 1
                                color: isDarkMode ? "#2A2A2A" : "#E8E8E8"
                            }

                            // 服务器位置
                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 12

                                FlagIcon {
                                    size: 24
                                    countryCode: serverCountryCode
                                }

                                Label {
                                    text: serverName
                                    font.pixelSize: 14
                                    font.bold: true
                                    color: Theme.colors.textPrimary
                                    elide: Text.ElideRight
                                    Layout.fillWidth: true
                                }

                                // 箭头按钮
                                Rectangle {
                                    Layout.preferredWidth: 28
                                    Layout.preferredHeight: 28
                                    radius: 14
                                    color: arrowMouseArea.containsMouse ? (isDarkMode ? "#3A3A3A" : "#E0E0E0") : "transparent"

                                    Label {
                                        text: "›"
                                        font.pixelSize: 20
                                        color: isDarkMode ? "#666666" : "#CCCCCC"
                                        anchors.centerIn: parent
                                    }

                                    MouseArea {
                                        id: arrowMouseArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            serverSelectDialog.open()
                                        }
                                    }
                                }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                serverSelectDialog.open()
                            }
                            propagateComposedEvents: false
                            z: -1
                        }
                    }
                }

                // 第一行统计：延迟、上传、下载
                GridLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 10
                    // 移动端使用2列，桌面端使用3列
                    columns: (mainWindow && mainWindow.isMobile) ? 2 : 3
                    rowSpacing: (mainWindow && mainWindow.isMobile) ? 10 : 8
                    columnSpacing: (mainWindow && mainWindow.isMobile) ? 10 : 8

                    // 延迟/Ping（显示连接后的实际延时）
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: (mainWindow && mainWindow.isMobile) ? 80 : 88
                        radius: (mainWindow && mainWindow.isMobile) ? 12 : 16
                        color: Theme.colors.surface
                        border.color: isDarkMode ? "#2A2A2A" : "#E8E8E8"
                        border.width: 1

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.topMargin: 6    // ⭐ 顶部间距改为6px
                            anchors.bottomMargin: 6  // ⭐ 底部间距改为6px
                            spacing: 4  // ⭐ 缩小元素间距

                            Label {
                                text: "📡"
                                font.pixelSize: 24
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Label {
                                text: {
                                    if (!isConnected) return "--"
                                    if (!vpnManager) return "⚡"
                                    var delay = vpnManager.currentDelay
                                    if (delay < 0) return qsTr("Testing...")
                                    if (delay === 0) return qsTr("Timeout")
                                    return delay + " ms"
                                }
                                font.pixelSize: 13
                                font.bold: true
                                color: {
                                    if (!isConnected || !vpnManager) return Theme.colors.textPrimary
                                    var delay = vpnManager.currentDelay
                                    if (delay < 0) return isDarkMode ? "#999999" : "#666666"
                                    if (delay === 0) return "#FF4444"
                                    if (delay < 100) return "#4CAF50"
                                    if (delay < 200) return "#FFC107"
                                    return "#FF5722"
                                }
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Label {
                                text: qsTr("Latency")
                                font.pixelSize: 11
                                color: isDarkMode ? "#999999" : "#666666"
                                Layout.alignment: Qt.AlignHCenter
                            }
                        }
                    }

                    // 上传总量
                    Rectangle {
                        id: uploadCard
                        Layout.fillWidth: true
                        Layout.preferredHeight: (mainWindow && mainWindow.isMobile) ? 80 : 88
                        radius: (mainWindow && mainWindow.isMobile) ? 12 : 16
                        color: Theme.colors.surface
                        border.color: isDarkMode ? "#2A2A2A" : "#E8E8E8"
                        border.width: 1

                        property string uploadText: "0 B"

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.topMargin: 6    // ⭐ 顶部间距改为6px
                            anchors.bottomMargin: 6  // ⭐ 底部间距改为6px
                            spacing: 4  // ⭐ 缩小元素间距

                            Label {
                                text: "↑"
                                font.pixelSize: 24
                                font.bold: true
                                color: "#4CAF50"
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Label {
                                text: uploadCard.uploadText
                                font.pixelSize: 13
                                font.bold: true
                                color: Theme.colors.textPrimary
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Label {
                                text: qsTr("Upload")
                                font.pixelSize: 11
                                color: isDarkMode ? "#999999" : "#666666"
                                Layout.alignment: Qt.AlignHCenter
                            }
                        }
                    }

                    // 下载总量
                    Rectangle {
                        id: downloadCard
                        Layout.fillWidth: true
                        Layout.preferredHeight: (mainWindow && mainWindow.isMobile) ? 80 : 88
                        radius: (mainWindow && mainWindow.isMobile) ? 12 : 16
                        color: Theme.colors.surface
                        border.color: isDarkMode ? "#2A2A2A" : "#E8E8E8"
                        border.width: 1

                        property string downloadText: "0 B"

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.topMargin: 6    // ⭐ 顶部间距改为6px
                            anchors.bottomMargin: 6  // ⭐ 底部间距改为6px
                            spacing: 4  // ⭐ 缩小元素间距

                            Label {
                                text: "↓"
                                font.pixelSize: 24
                                font.bold: true
                                color: "#2196F3"
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Label {
                                text: downloadCard.downloadText
                                font.pixelSize: 13
                                font.bold: true
                                color: Theme.colors.textPrimary
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Label {
                                text: qsTr("Download")
                                font.pixelSize: 11
                                color: isDarkMode ? "#999999" : "#666666"
                                Layout.alignment: Qt.AlignHCenter
                            }
                        }
                    }

                    // 连接时长
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: (mainWindow && mainWindow.isMobile) ? 80 : 88
                        radius: (mainWindow && mainWindow.isMobile) ? 12 : 16
                        color: Theme.colors.surface
                        border.color: isDarkMode ? "#2A2A2A" : "#E8E8E8"
                        border.width: 1

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.topMargin: (mainWindow && mainWindow.isMobile) ? 8 : 6
                            anchors.bottomMargin: (mainWindow && mainWindow.isMobile) ? 8 : 6
                            spacing: (mainWindow && mainWindow.isMobile) ? 3 : 4

                            IconSymbol {
                                icon: "timer"
                                size: (mainWindow && mainWindow.isMobile) ? 20 : 24
                                color: Theme.colors.textPrimary
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Label {
                                text: connectedDurationText
                                font.pixelSize: 13
                                font.bold: true
                                color: Theme.colors.textPrimary
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Label {
                                text: qsTr("Connection Duration")
                                font.pixelSize: 11
                                color: isDarkMode ? "#999999" : "#666666"
                                Layout.alignment: Qt.AlignHCenter
                            }
                        }
                    }

                    // 连接协议
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: (mainWindow && mainWindow.isMobile) ? 80 : 88
                        radius: (mainWindow && mainWindow.isMobile) ? 12 : 16
                        color: Theme.colors.surface
                        border.color: isDarkMode ? "#2A2A2A" : "#E8E8E8"
                        border.width: 1

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.topMargin: (mainWindow && mainWindow.isMobile) ? 8 : 6
                            anchors.bottomMargin: (mainWindow && mainWindow.isMobile) ? 8 : 6
                            spacing: (mainWindow && mainWindow.isMobile) ? 3 : 4

                            Label {
                                text: "🔐"
                                font.pixelSize: (mainWindow && mainWindow.isMobile) ? 20 : 24
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Label {
                                text: serverProtocol !== "" ? serverProtocol : "--"
                                font.pixelSize: 13
                                font.bold: true
                                color: Theme.colors.textPrimary
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Label {
                                text: qsTr("Protocol")
                                font.pixelSize: 11
                                color: isDarkMode ? "#999999" : "#666666"
                                Layout.alignment: Qt.AlignHCenter
                            }
                        }
                    }

                    // IP 地址
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: (mainWindow && mainWindow.isMobile) ? 80 : 88
                        radius: (mainWindow && mainWindow.isMobile) ? 12 : 16
                        color: Theme.colors.surface
                        border.color: isDarkMode ? "#2A2A2A" : "#E8E8E8"
                        border.width: 1

                        ColumnLayout {
                            anchors.fill: parent
                            anchors.topMargin: (mainWindow && mainWindow.isMobile) ? 8 : 6
                            anchors.bottomMargin: (mainWindow && mainWindow.isMobile) ? 8 : 6
                            spacing: (mainWindow && mainWindow.isMobile) ? 3 : 4

                            Label {
                                text: "🌐"
                                font.pixelSize: (mainWindow && mainWindow.isMobile) ? 20 : 24
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Label {
                                text: {
                                    if (!isConnected) return qsTr("Not Connected")
                                    if (!vpnManager) return "--"
                                    var ip = vpnManager.currentIP
                                    if (!ip || ip === "") return qsTr("Testing...")
                                    return ip
                                }
                                font.pixelSize: 13
                                font.bold: true
                                color: {
                                    if (!isConnected || !vpnManager) return isDarkMode ? "#999999" : "#666666"
                                    var ip = vpnManager.currentIP
                                    if (!ip || ip === "") return isDarkMode ? "#999999" : "#666666"
                                    return Theme.colors.textPrimary
                                }
                                Layout.alignment: Qt.AlignHCenter
                            }

                            Label {
                                text: qsTr("IP Address")
                                font.pixelSize: 11
                                color: isDarkMode ? "#999999" : "#666666"
                                Layout.alignment: Qt.AlignHCenter
                            }
                        }
                    }
                }

                // 延时曲线图（仅桌面平台，已连接且间隔>0时显示）
                Rectangle {
                    id: latencyChartCard
                    visible: {
                        var isDesktop = Qt.platform.os !== "android" && Qt.platform.os !== "ios"
                        var testEnabled = configManager && configManager.latencyTestInterval > 0
                        var hasData = vpnManager && vpnManager.latencyHistory && vpnManager.latencyHistory.length > 1
                        return isDesktop && testEnabled && isConnected && hasData
                    }
                    Layout.fillWidth: true
                    Layout.topMargin: 10
                    Layout.preferredHeight: 160
                    radius: 20
                    color: Theme.colors.surface
                    border.color: isDarkMode ? "#2A2A2A" : "#E8E8E8"
                    border.width: 1

                    // 标题
                    Label {
                        id: chartTitle
                        anchors.top: parent.top
                        anchors.left: parent.left
                        anchors.margins: 16
                        text: qsTr("Latency History")
                        font.pixelSize: 13
                        font.bold: true
                        color: Theme.colors.textSecondary
                    }

                    // 延时曲线图
                    Canvas {
                        id: latencyCanvas
                        anchors.fill: parent
                        anchors.topMargin: 40
                        anchors.leftMargin: 16
                        anchors.rightMargin: 16
                        anchors.bottomMargin: 16

                        property var dataPoints: vpnManager ? vpnManager.latencyHistory : []

                        onDataPointsChanged: requestPaint()

                        Connections {
                            target: vpnManager
                            function onLatencyHistoryChanged() {
                                latencyCanvas.dataPoints = vpnManager.latencyHistory
                            }
                        }

                        onPaint: {
                            var ctx = getContext("2d")
                            ctx.clearRect(0, 0, width, height)

                            var points = dataPoints
                            if (!points || points.length < 2) return

                            // 找最大最小值
                            var maxLatency = 0
                            var minLatency = Number.MAX_VALUE
                            for (var i = 0; i < points.length; i++) {
                                var lat = points[i].latency
                                if (lat > maxLatency) maxLatency = lat
                                if (lat < minLatency) minLatency = lat
                            }
                            // 确保有合理的范围
                            maxLatency = Math.max(maxLatency, 100)
                            minLatency = Math.max(0, minLatency - 20)
                            var range = maxLatency - minLatency
                            if (range < 50) range = 50

                            // 绘制网格线
                            ctx.strokeStyle = isDarkMode ? "#333333" : "#EEEEEE"
                            ctx.lineWidth = 1
                            ctx.setLineDash([3, 3])

                            // 3条水平线
                            for (var j = 0; j <= 2; j++) {
                                var y = height * j / 2
                                ctx.beginPath()
                                ctx.moveTo(0, y)
                                ctx.lineTo(width, y)
                                ctx.stroke()
                            }
                            ctx.setLineDash([])

                            // 绘制刻度值
                            ctx.fillStyle = isDarkMode ? "#666666" : "#999999"
                            ctx.font = "10px sans-serif"
                            ctx.textAlign = "left"
                            ctx.fillText(Math.round(maxLatency) + "ms", 2, 10)
                            ctx.fillText(Math.round(minLatency + range / 2) + "ms", 2, height / 2 + 4)
                            ctx.fillText(Math.round(minLatency) + "ms", 2, height - 2)

                            // 绘制折线
                            ctx.strokeStyle = "#4CAF50"
                            ctx.lineWidth = 2
                            ctx.beginPath()

                            var startX = 40  // 留出刻度空间
                            var drawWidth = width - startX - 10

                            for (var k = 0; k < points.length; k++) {
                                var x = startX + (drawWidth * k / (points.length - 1))
                                var latency = points[k].latency
                                var yPos = height - ((latency - minLatency) / range * height)
                                yPos = Math.max(5, Math.min(height - 5, yPos))

                                if (k === 0) {
                                    ctx.moveTo(x, yPos)
                                } else {
                                    ctx.lineTo(x, yPos)
                                }
                            }
                            ctx.stroke()

                            // 绘制数据点
                            ctx.fillStyle = "#4CAF50"
                            for (var m = 0; m < points.length; m++) {
                                var px = startX + (drawWidth * m / (points.length - 1))
                                var py = height - ((points[m].latency - minLatency) / range * height)
                                py = Math.max(5, Math.min(height - 5, py))

                                ctx.beginPath()
                                ctx.arc(px, py, 3, 0, 2 * Math.PI)
                                ctx.fill()
                            }
                        }
                    }
                }

                // 连接设置卡片
                Rectangle {
                    Layout.fillWidth: true
                    Layout.topMargin: 10
                    Layout.preferredHeight: 220
                    radius: 20
                    color: Theme.colors.surface
                    border.color: isDarkMode ? "#2A2A2A" : "#E8E8E8"
                    border.width: 1

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 24
                        spacing: 16

                        Label {
                            text: qsTr("Connect Settings")
                            font.pixelSize: 14
                            font.bold: true
                            color: Theme.colors.textPrimary
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            height: 1
                            color: isDarkMode ? "#2A2A2A" : "#E8E8E8"
                        }

                        // TUN 模式切换
                        // iOS 上只支持 TUN 模式（Proxy 模式需要 MDM 部署）
                        // 所以在 iOS 上隐藏此选项
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10
                            visible: Qt.platform.os !== "ios"  // iOS 上隐藏

                            ColumnLayout {
                                spacing: 2

                                Label {
                                    text: qsTr("TUN Mode")
                                    font.pixelSize: 14
                                    font.weight: Font.Medium
                                    color: Theme.colors.textPrimary
                                }

                                Label {
                                    text: qsTr("VPN/Proxy")
                                    font.pixelSize: 11
                                    color: isDarkMode ? "#999999" : "#666666"
                                }
                            }

                            Item { Layout.fillWidth: true }

                            CustomSwitch {
                                id: tunModeSwitch
                                checked: configManager ? (configManager.vpnMode === 0) : false

                                onToggled: {
                                    if (configManager) {
                                        // 0 = TUN, 1 = Proxy (根据 ConfigManager.h 的 VPNMode enum)
                                        var newMode = checked ? 0 : 1
                                        configManager.vpnMode = newMode
                                        configManager.save()
                                    }
                                }
                            }
                        }

                        // 运行模式选择
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10

                            ColumnLayout {
                                spacing: 2

                                Label {
                                    text: qsTr("Running Mode")
                                    font.pixelSize: 14
                                    font.weight: Font.Medium
                                    color: Theme.colors.textPrimary
                                }

                                Label {
                                    text: qsTr("Traffic routing")
                                    font.pixelSize: 11
                                    color: isDarkMode ? "#999999" : "#666666"
                                }
                            }

                            Item { Layout.fillWidth: true }

                            ComboBox {
                                id: routingModeCombo
                                Layout.preferredWidth: 100
                                model: [qsTr("Global"), qsTr("Rule"), qsTr("Subscription")]

                                // 枚举映射：Global=0, Rule=1, Direct=2(未使用), Subscription=3
                                // ComboBox索引：0=Global, 1=Rule, 2=Subscription
                                function enumToIndex(mode) {
                                    if (mode === 3) return 2  // Subscription
                                    if (mode === 2) return 1  // Direct -> Rule (兼容旧配置)
                                    return mode               // Global=0, Rule=1
                                }

                                function indexToEnum(idx) {
                                    if (idx === 2) return 3   // Subscription
                                    return idx                // Global=0, Rule=1
                                }

                                Component.onCompleted: {
                                    if (configManager) {
                                        currentIndex = enumToIndex(configManager.routingMode)
                                    }
                                }

                                Connections {
                                    target: configManager
                                    function onRoutingModeChanged() {
                                        routingModeCombo.currentIndex = routingModeCombo.enumToIndex(configManager.routingMode)
                                    }
                                }

                                onActivated: {
                                    if (configManager) {
                                        configManager.routingMode = indexToEnum(currentIndex)
                                    }
                                }

                                implicitHeight: {
                                    var isMobile = Qt.platform.os === "android" || Qt.platform.os === "ios"
                                    return isMobile ? 36 : 32
                                }
                            }
                        }

                        Label {
                            Layout.fillWidth: true
                            text: qsTr("* Changes to connection settings require reconnecting to take effect")
                            font.pixelSize: 11
                            color: Theme.colors.warning
                            font.italic: true
                            wrapMode: Text.WordWrap
                        }
                    }
                }
            }

            Item { Layout.preferredHeight: 30 }
        }
    }
}
