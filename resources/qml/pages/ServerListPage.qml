// resources/qml/pages/ServerListPage.qml
import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 2.15
import JinGo 1.0

Rectangle {
    id: serverListPage
    readonly property var mainWindow: Qt.application.topLevelWindow || null
    color: Theme.colors.pageBackground

    readonly property bool isDarkMode: mainWindow ? mainWindow.isDarkMode : false

    // Changed from readonly binding to simple property to avoid accessing vpnManager during init
    property var currentServer: null

    property int serverCount: 0
    property bool isManuallyUpdating: false
    property var groupedServers: ({}) // 按地区分组的服务器
    property var expandedGroups: ({}) // 展开状态
    property bool isRefreshing: false // 是否正在刷新服务器列表，防止重复调用
    property string searchText: ""    // 搜索文本
    property string protocolFilter: "" // 协议筛选（空=全部）
    property string speedTestingServerId: "" // 正在测速的服务器ID（空表示没有在测速）
    property int speedTestDuration: 10  // 测速持续时间（秒）
    property var speedTestResults: ({}) // 保存测速结果 {serverId: {ip, asn, isp, country, speed}}
    // 最后一次测速的服务器ID和结果（用于触发UI更新）
    property string lastTestedServerId: ""
    property string lastTestedIp: ""
    property string lastTestedIpInfo: ""
    property string lastTestedSpeed: ""
    property bool waitingForIpInfo: false // 是否正在等待IP信息
    property var batchSpeedTestQueue: [] // 批量网速测试队列
    property bool isBatchSpeedTesting: false // 是否正在批量测试网速
    property int batchSpeedTestTotal: 0 // 批量测试总数
    property int batchSpeedTestCompleted: 0 // 批量测试已完成数
    property bool isDownloading: false // 是否正在下载测速文件
    property real downloadStartTime: 0 // 下载开始时间
    property int downloadedBytes: 0 // 已下载字节数

    // 使用 ListModel 作为中介，避免直接绑定到 C++ QList
    ListModel {
        id: serversModel
    }

    // 安全地从 C++ 加载服务器列表到 ListModel（增量更新模式）
    // forceClear: 是否强制清空（仅在用户手动刷新时为true）
    function loadServersToModel(forceClear) {
        if (!serverListViewModel) {
            return
        }

        // 如果正在加载，不要访问服务器列表
        if (serverListViewModel.isLoading) {
            return
        }

        // 后台更新检查
        if (typeof backgroundDataUpdater !== 'undefined' && backgroundDataUpdater && backgroundDataUpdater.isUpdating) {
            return
        }

        // 获取服务器列表
        var servers = null
        try {
            servers = serverListViewModel.servers
        } catch (e) {
            return
        }

        if (!servers || typeof servers.length === 'undefined') {
            return
        }

        // 第一步：提取新数据到临时数组，并建立 ID 映射
        var newServers = []
        var newServerIds = {}  // ID -> index 映射

        for (var i = 0; i < servers.length; i++) {
            var server = servers[i]
            if (!server) continue

            try {
                var testAccess = server.id
                if (testAccess === undefined || testAccess === null) continue

                var serverData = {
                    "serverId": server.id || "",
                    "serverName": server.name || "Unknown",
                    "serverFlag": server.countryFlag || "",
                    "serverProtocol": server.protocol || "",
                    "serverLatency": server.latency || -1,
                    "serverLocation": server.location || "",
                    "serverAddress": server.address || "",
                    "serverPort": server.port || 0,
                    "serverCountryCode": server.countryCode || "",
                    "serverContinent": server.continent || "",
                    "serverBandwidth": server.bandwidth || "",
                    "serverLoad": server.serverLoad || 0,
                    "isFavorite": server.isFavorite || false,
                    "isPro": server.isPro || false,
                    "isTestingSpeed": server.isTestingSpeed || false
                }

                if (serverData.serverId && serverData.serverId !== "") {
                    newServerIds[serverData.serverId] = newServers.length
                    newServers.push(serverData)
                }
            } catch (e) {
                continue
            }
        }

        // 强制清空模式：直接替换
        if (forceClear) {
            serversModel.clear()
            for (var k = 0; k < newServers.length; k++) {
                serversModel.append(newServers[k])
            }
            return
        }

        // ========== 增量更新模式 ==========
        // 建立旧列表的 ID 映射
        var oldServerIds = {}  // ID -> index 映射
        for (var m = 0; m < serversModel.count; m++) {
            var oldItem = serversModel.get(m)
            if (oldItem && oldItem.serverId) {
                oldServerIds[oldItem.serverId] = m
            }
        }

        // 第二步：删除不在新列表中的项（从后往前删除，避免索引偏移）
        for (var d = serversModel.count - 1; d >= 0; d--) {
            var item = serversModel.get(d)
            if (item && item.serverId && !(item.serverId in newServerIds)) {
                serversModel.remove(d)
            }
        }

        // 第三步：更新已存在的项，添加新项
        // 先处理更新，再处理添加，保持顺序
        var processedIds = {}

        // 按新列表顺序遍历
        for (var n = 0; n < newServers.length; n++) {
            var newItem = newServers[n]
            var existingIndex = -1

            // 在当前模型中查找这个ID
            for (var f = 0; f < serversModel.count; f++) {
                var checkItem = serversModel.get(f)
                if (checkItem && checkItem.serverId === newItem.serverId) {
                    existingIndex = f
                    break
                }
            }

            if (existingIndex >= 0) {
                // 已存在：检查是否需要更新属性
                var oldData = serversModel.get(existingIndex)
                if (hasServerDataChanged(oldData, newItem)) {
                    serversModel.set(existingIndex, newItem)
                }
                processedIds[newItem.serverId] = true
            } else {
                // 新服务器：添加到列表末尾
                serversModel.append(newItem)
                processedIds[newItem.serverId] = true
            }
        }
    }

    // 检查服务器数据是否有变化
    function hasServerDataChanged(oldData, newData) {
        if (!oldData || !newData) return true
        return oldData.serverName !== newData.serverName ||
               oldData.serverLatency !== newData.serverLatency ||
               oldData.serverLocation !== newData.serverLocation ||
               oldData.serverProtocol !== newData.serverProtocol ||
               oldData.isTestingSpeed !== newData.isTestingSpeed ||
               oldData.isFavorite !== newData.isFavorite
    }

    // 根据 ID 安全地从 C++ 获取服务器对象（用于操作，不用于显示）
    function getServerById(serverId) {
        if (!serverId || serverId === "") {
            return null
        }

        if (!serverListViewModel) {
            return null
        }

        // 【关键修复】如果正在加载，不要访问服务器列表
        if (serverListViewModel.isLoading) {
            return null
        }

        try {
            var servers = serverListViewModel.servers
            if (!servers || typeof servers.length === 'undefined') {
                return null
            }

            // 快速遍历查找
            for (var i = 0; i < servers.length; i++) {
                try {
                    var server = servers[i]
                    if (server && server.id === serverId) {
                        return server
                    }
                } catch (e) {
                    // 对象可能已被删除，跳过
                    continue
                }
            }

        } catch (e) {
        }
        return null
    }

    // 安全地获取VPN连接状态
    function safeIsConnected() {
        try {
            return vpnManager && typeof vpnManager.isConnected !== 'undefined' && vpnManager.isConnected
        } catch (e) {
            return false
        }
    }

    function safeIsConnecting() {
        try {
            return vpnManager && typeof vpnManager.isConnecting !== 'undefined' && vpnManager.isConnecting
        } catch (e) {
            return false
        }
    }

    // 安全地更新当前服务器
    function updateCurrentServer() {
        try {
            if (vpnManager && typeof vpnManager.currentServer !== 'undefined') {
                currentServer = vpnManager.currentServer
            } else {
                currentServer = null
            }
        } catch (e) {
            currentServer = null
        }
    }

    // 检查服务器是否匹配搜索和筛选条件
    function serverMatchesFilter(server) {
        if (!server) return false

        // 协议筛选
        if (protocolFilter && protocolFilter !== "") {
            var serverProtocol = (server.serverProtocol || server.protocol || "").toLowerCase()
            if (serverProtocol !== protocolFilter.toLowerCase()) {
                return false
            }
        }

        // 搜索文本筛选（匹配名称或位置）
        if (searchText && searchText !== "") {
            var searchLower = searchText.toLowerCase()
            var name = (server.serverName || server.name || "").toLowerCase()
            var location = (server.serverLocation || server.location || "").toLowerCase()
            var address = (server.serverAddress || server.address || "").toLowerCase()

            if (!name.includes(searchLower) && !location.includes(searchLower) && !address.includes(searchLower)) {
                return false
            }
        }

        return true
    }

    // 分组服务器 - 按洲分组（从 ListModel 读取数据副本）
    function groupServersByCountry() {
        try {
            var groups = {}
            var filteredCount = 0

            for (var i = 0; i < serversModel.count; i++) {
                var server = serversModel.get(i)

                // 严格的null检查
                if (!server) {
                    continue
                }

                // 应用搜索和筛选条件
                if (!serverMatchesFilter(server)) {
                    continue
                }

                // 安全地访问属性 - 从ListModel复制的数据
                var groupKey = "其他"
                try {
                    if (server.serverContinent !== undefined && server.serverContinent !== null && server.serverContinent !== "") {
                        groupKey = String(server.serverContinent)
                    } else if (server.serverLocation !== undefined && server.serverLocation !== null && server.serverLocation !== "") {
                        groupKey = String(server.serverLocation)
                    }
                } catch (e) {
                    continue
                }

                if (!groups[groupKey]) {
                    groups[groupKey] = []
                }
                // 复制数据到普通对象而不是存储 ListElement 引用
                groups[groupKey].push({
                    id: server.serverId,
                    name: server.serverName,
                    countryFlag: server.serverFlag,
                    protocol: server.serverProtocol,
                    latency: server.serverLatency,
                    location: server.serverLocation,
                    address: server.serverAddress,
                    port: server.serverPort,
                    countryCode: server.serverCountryCode,
                    continent: server.serverContinent,
                    bandwidth: server.serverBandwidth,
                    serverLoad: server.serverLoad,
                    isFavorite: server.isFavorite,
                    isPro: server.isPro,
                    isTestingSpeed: server.isTestingSpeed || false
                })
                filteredCount++
            }

            groupedServers = groups

            // 更新显示的服务器数量（筛选后）
            serverCount = filteredCount

            // 默认展开所有分组
            var expanded = {}
            for (var key in groups) {
                expanded[key] = true
            }
            expandedGroups = expanded
        } catch (error) {
            groupedServers = {}
            expandedGroups = {}
        }
    }

    Connections {
        target: serverListViewModel

        function onServersChanged() {
            // 【关键修复】第一次收到 serversChanged 信号时，标记为已初始化
            if (!isInitialized) {
                isInitialized = true
            }

            // 【不强制清空】这可能是排序或筛选，不需要清空，只更新显示
            loadServersToModel(false)

            serverCount = serversModel.count
            if (isManuallyUpdating && serverCount > 0) {
                isManuallyUpdating = false
            }
            // 刷新完成，重置标志
            isRefreshing = false

            // 然后进行分组
            groupServersByCountry()

            // 通知C++层服务器列表刷新完成，恢复连接按钮状态
            if (serverListViewModel) {
                serverListViewModel.finishRefreshingServers()
            }
        }

        function onIsLoadingChanged() {
            // 加载完成后仅更新计数和分组
            // 【修复】不再强制清空列表：强制清空会导致后台自动更新（3小时）时列表短暂消失
            // onServersChanged 已通过增量更新处理列表变化，此处无需重复操作
            if (!serverListViewModel.isLoading && isInitialized) {
                Qt.callLater(function() {
                    serverCount = serversModel.count
                    groupServersByCountry()
                })
            }
        }

        // 排序完成：强制重建列表（incremental 不处理顺序变化）
        function onServersSorted() {
            Qt.callLater(function() {
                loadServersToModel(true)
                groupServersByCountry()
            })
        }

        // 单个服务器延时测试完成时更新UI（使用防抖，避免频繁刷新）
        function onServerTestCompleted(server) {
            // 使用防抖定时器，避免测试多个服务器时频繁刷新
            latencyRefreshDebounceTimer.restart()
        }

        // 所有延时测试完成时更新UI
        function onAllTestsCompleted() {
            // 停止防抖定时器，立即刷新
            latencyRefreshDebounceTimer.stop()
            Qt.callLater(function() {
                loadServersToModel(false)
                groupServersByCountry()
            })
        }
    }

    // 监听VPN状态变化，更新当前服务器
    // 【增强防御】添加null检查，确保vpnManager存在时才连接信号
    Connections {
        target: typeof vpnManager !== 'undefined' && vpnManager ? vpnManager : null
        enabled: target !== null

        function onCurrentServerChanged() {
            try {
                updateCurrentServer()
            } catch (e) {
                // 忽略初始化错误
            }
        }

        function onStateChanged() {
            try {
                updateCurrentServer()
                // 如果正在测速且刚连接成功，开始等待IP信息
                if (speedTestingServerId !== "" && safeIsConnected() && !waitingForIpInfo) {
                    waitingForIpInfo = true
                    ipWaitTimer.start()
                }
            } catch (e) {
                // 忽略错误
            }
        }
    }

    // 监听 VPNManager 的 IP 信息更新
    // 【增强防御】添加try-catch和null检查
    Connections {
        target: typeof vpnManager !== 'undefined' && vpnManager ? vpnManager : null
        // 始终启用，在handler内部检查条件（避免时序问题）
        enabled: target !== null

        function onConnectionInfoUpdated() {
            try {
                // 只有在测速模式下才处理
                if (speedTestingServerId === "") {
                    return
                }

                // 获取 IP 信息
                var ip = vpnManager.currentIP || ""
                var ipInfo = vpnManager.ipInfo || ""

                // 如果有有效的 IP 信息，保存它
                if (ip !== "") {
                    // 保存 IP 信息到 ViewModel（持久化）
                    if (serverListViewModel) {
                        var vmResult = serverListViewModel.getSpeedTestResult(speedTestingServerId) || {}
                        vmResult.ip = ip
                        vmResult.ipInfo = ipInfo
                        serverListViewModel.setSpeedTestResult(speedTestingServerId, vmResult)
                    }

                    // 保存 IP 信息到本地结果（兼容现有代码）
                    var newResults = Object.assign({}, speedTestResults)
                    if (!newResults[speedTestingServerId]) {
                        newResults[speedTestingServerId] = {}
                    }
                    newResults[speedTestingServerId].ip = ip
                    newResults[speedTestingServerId].ipInfo = ipInfo
                    speedTestResults = newResults

                    // 更新 lastTested 属性以触发UI更新
                    lastTestedServerId = speedTestingServerId
                    lastTestedIp = ip
                    lastTestedIpInfo = ipInfo

                    // 如果正在等待IP，则可以开始测速了
                    if (waitingForIpInfo) {
                        ipWaitTimer.stop()
                        waitingForIpInfo = false
                        speedTestTimer.start()
                    }
                }
            } catch (e) {
                // 忽略错误
            }
        }
    }

    // IP 信息等待超时计时器（最多等待 5 秒）
    Timer {
        id: ipWaitTimer
        interval: 5000
        running: false
        repeat: false
        onTriggered: {
            if (speedTestingServerId !== "" && waitingForIpInfo) {
                waitingForIpInfo = false
                // 即使没有获取到 IP 也开始测速
                speedTestTimer.start()
            }
        }
    }

    // 测速计时器 - 触发实际下载测试
    Timer {
        id: speedTestTimer
        interval: 500  // 延迟500ms确保VPN连接稳定
        running: false
        repeat: false
        onTriggered: {
            if (speedTestingServerId !== "") {
                startDownloadSpeedTest()
            }
        }
    }

    // 下载测速超时计时器（最多等待60秒）
    Timer {
        id: downloadTimeoutTimer
        interval: 60000  // 60秒超时
        running: false
        repeat: false
        onTriggered: {
            if (isDownloading) {
                finishSpeedTest("超时")
            }
        }
    }

    // 开始下载测速 - 使用 C++ 的 performSpeedTest
    function startDownloadSpeedTest() {
        if (speedTestingServerId === "") {
            return
        }
        isDownloading = true
        // 调用 C++ 的测速函数（不需要VPN连接）
        if (vpnManager && typeof vpnManager.testServerSpeed === 'function') {
            vpnManager.testServerSpeed(speedTestingServerId)
        } else {
            finishSpeedTest("--")
        }
    }

    // 监听 C++ 测速完成信号
    Connections {
        target: vpnManager
        enabled: speedTestingServerId !== ""

        function onSpeedTestCompleted(speedBps, error) {
            if (speedTestingServerId === "") return
            if (error === "" && speedBps > 0) {
                finishSpeedTest(formatSpeed(speedBps))
            } else {
                finishSpeedTest("--")
            }
        }
    }

    // 格式化速度显示
    function formatSpeed(bytesPerSecond) {
        if (bytesPerSecond >= 1024 * 1024) {
            return (bytesPerSecond / (1024 * 1024)).toFixed(2) + " MB/s"
        } else if (bytesPerSecond >= 1024) {
            return (bytesPerSecond / 1024).toFixed(1) + " KB/s"
        } else {
            return bytesPerSecond.toFixed(0) + " B/s"
        }
    }

    // 完成测速
    function finishSpeedTest(speedStr) {
        isDownloading = false

        if (speedTestingServerId === "") return

        // 保存速度到结果
        var savedServerId = speedTestingServerId  // 先保存ID，因为后面会清空

        // 保存到 ViewModel（持久化，切换页面不会丢失）
        if (serverListViewModel) {
            var result = serverListViewModel.getSpeedTestResult(savedServerId) || {}
            result.speed = speedStr
            serverListViewModel.setSpeedTestResult(savedServerId, result)
        }

        // 同时更新本地属性（兼容现有代码）
        var newResults = Object.assign({}, speedTestResults)
        if (!newResults[savedServerId]) {
            newResults[savedServerId] = {}
        }
        newResults[savedServerId].speed = speedStr
        speedTestResults = newResults

        // 更新 lastTested 属性以触发UI更新
        lastTestedServerId = savedServerId
        lastTestedSpeed = speedStr

        var testedServerId = speedTestingServerId
        speedTestingServerId = ""

        // 断开VPN连接
        if (serverListViewModel) {
            serverListViewModel.disconnect()
        }

        // 如果是批量测试，继续下一个
        if (isBatchSpeedTesting && batchSpeedTestQueue.length > 0) {
            batchSpeedTestCompleted++
            // 延迟一下再测试下一个
            batchNextTimer.start()
        } else if (isBatchSpeedTesting) {
            // 批量测试完成
            batchSpeedTestCompleted++
            isBatchSpeedTesting = false
        }
    }

    // 批量测试下一个服务器的延迟计时器
    Timer {
        id: batchNextTimer
        interval: 2000  // 等待2秒再测下一个
        running: false
        repeat: false
        onTriggered: {
            startNextBatchSpeedTest()
        }
    }

    // 开始批量网速测试
    function startBatchSpeedTest() {
        if (!serverListViewModel) return

        var servers = serverListViewModel.servers
        if (!servers || servers.length === 0) return

        // 构建测试队列
        batchSpeedTestQueue = []
        for (var i = 0; i < servers.length; i++) {
            var server = servers[i]
            if (server && server.id) {
                batchSpeedTestQueue.push(server.id)
            }
        }

        if (batchSpeedTestQueue.length === 0) return

        isBatchSpeedTesting = true
        batchSpeedTestTotal = batchSpeedTestQueue.length
        batchSpeedTestCompleted = 0

        // 开始第一个
        startNextBatchSpeedTest()
    }

    // 测试下一个服务器
    function startNextBatchSpeedTest() {
        if (batchSpeedTestQueue.length === 0) {
            isBatchSpeedTesting = false
            return
        }

        var serverId = batchSpeedTestQueue.shift()
        var realServerObj = getServerById(serverId)

        if (!realServerObj) {
            // 跳过无效服务器，继续下一个
            if (batchSpeedTestQueue.length > 0) {
                startNextBatchSpeedTest()
            } else {
                isBatchSpeedTesting = false
            }
            return
        }

        // 设置测速状态
        speedTestingServerId = serverId

        // 如果VPN已连接，先断开
        if (safeIsConnected()) {
            serverListViewModel.disconnect()
            // 延迟后连接
            Qt.callLater(function() {
                serverListViewModel.connectToServer(realServerObj)
            })
        } else {
            serverListViewModel.connectToServer(realServerObj)
        }
    }

    // 组件完成时初始化（主要初始化方式）
    Component.onCompleted: {
        // 安全更新当前服务器状态
        updateCurrentServer()

        // 直接在下一事件循环初始化，后台线程会通过信号通知更新
        Qt.callLater(initializeServerList)
    }

    // 监听页面可见性，只在页面显示时初始化（备用方式）
    onVisibleChanged: {
        if (visible) {
            if (!isInitialized) {
                serverListInitTimer.start()
            } else if (serversModel.count === 0) {
                // 如果已经初始化但模型是空的，强制重新加载（可能错过了 serversChanged 信号）
                Qt.callLater(function() {
                    loadServersToModel(false)
                    serverCount = serversModel.count || 0
                    groupServersByCountry()
                })
            }
        }
    }

    property bool isInitialized: false

    // 初始化函数
    function initializeServerList() {
        if (isInitialized) {
            return  // 防止重复初始化
        }

        isInitialized = true  // 先设置为已初始化，这样后续的 serversChanged 信号才会被处理

        try {
            // 【初始加载】不强制清空，因为模型本来就是空的
            loadServersToModel(false)

            serverCount = serversModel.count || 0
            groupServersByCountry()
        } catch (error) {
            serverCount = 0
        }
    }

    // 手动刷新函数（触发网络订阅更新）
    function triggerManualRefresh() {
        if (isRefreshing) {
            return
        }

        isRefreshing = true
        // isRefreshing 会在 onServersChanged 中重置为 false
        // 这里调用真正的网络刷新，而不是只从本地缓存加载
        if (serverListViewModel) {
            serverListViewModel.refreshServers()
        }
    }

    // 初始化定时器
    Timer {
        id: serverListInitTimer
        interval: 100
        running: false
        repeat: false
        onTriggered: {
            initializeServerList()
        }
    }

    // 搜索防抖定时器
    Timer {
        id: searchDebounceTimer
        interval: 300
        running: false
        repeat: false
        onTriggered: {
            groupServersByCountry()
        }
    }

    // 延时测试结果刷新防抖定时器（避免频繁刷新）
    Timer {
        id: latencyRefreshDebounceTimer
        interval: 500  // 500ms 防抖，平衡实时性和性能
        running: false
        repeat: false
        onTriggered: {
            loadServersToModel(false)
            groupServersByCountry()
        }
    }

    ColumnLayout {
        anchors.fill: parent
        anchors.margins: (mainWindow && mainWindow.isDesktop) ? 40 : 20
        spacing: 20

        // 标题栏
        Rectangle {
            Layout.fillWidth: true
            Layout.preferredHeight: 60
            color: Theme.colors.titleBarBackground
            radius: 12

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: 15
                anchors.rightMargin: 15
                spacing: 10

                Label {
                    text: qsTr("Servers") + " (" + serverCount + ")"
                    font.pixelSize: 18
                    font.bold: true
                    color: Theme.colors.titleBarText
                }

                // 搜索框（仅桌面端显示）
                Rectangle {
                    visible: (mainWindow && mainWindow.isDesktop) ? true : false
                    Layout.preferredWidth: 180
                    Layout.preferredHeight: 32
                    radius: 16
                    color: Qt.rgba(255/255, 255/255, 255/255, 0.1)
                    border.width: 1
                    border.color: searchInput.activeFocus ? Theme.colors.primary : Qt.rgba(255/255, 255/255, 255/255, 0.15)

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 8
                        spacing: 6

                        Label {
                            text: "🔍"
                            font.pixelSize: 12
                            opacity: 0.7
                        }

                        TextInput {
                            id: searchInput
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            verticalAlignment: TextInput.AlignVCenter
                            color: "#FFFFFF"
                            font.pixelSize: 13
                            clip: true
                            selectByMouse: true

                            property string placeholderText: qsTr("Search servers...")

                            Text {
                                anchors.fill: parent
                                verticalAlignment: Text.AlignVCenter
                                text: searchInput.placeholderText
                                color: "#999999"
                                font.pixelSize: 13
                                visible: !searchInput.text && !searchInput.activeFocus
                            }

                            onTextChanged: {
                                searchText = text
                                // 延迟更新分组以避免频繁刷新
                                searchDebounceTimer.restart()
                            }
                        }

                        // 清除按钮
                        Rectangle {
                            visible: searchInput.text.length > 0
                            width: 16
                            height: 16
                            radius: 8
                            color: clearSearchArea.containsMouse ? Qt.rgba(255/255, 255/255, 255/255, 0.3) : Qt.rgba(255/255, 255/255, 255/255, 0.15)

                            Label {
                                anchors.centerIn: parent
                                text: "✕"
                                font.pixelSize: 10
                                color: "#FFFFFF"
                            }

                            MouseArea {
                                id: clearSearchArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    searchInput.text = ""
                                    searchText = ""
                                    groupServersByCountry()
                                }
                            }
                        }
                    }
                }

                // 协议筛选下拉框（仅桌面端显示）
                ComboBox {
                    id: protocolFilterCombo
                    visible: (mainWindow && mainWindow.isDesktop) ? true : false
                    Layout.preferredWidth: 100
                    Layout.preferredHeight: 32
                    model: [qsTr("All"), "VMess", "VLess", "Trojan", "SS"]

                    onCurrentIndexChanged: {
                        if (currentIndex === 0) {
                            protocolFilter = ""
                        } else {
                            var protocols = ["", "vmess", "vless", "trojan", "shadowsocks"]
                            protocolFilter = protocols[currentIndex] || ""
                        }
                        groupServersByCountry()
                    }

                    background: Rectangle {
                        radius: 16
                        color: Qt.rgba(255/255, 255/255, 255/255, 0.1)
                        border.width: 1
                        border.color: Qt.rgba(255/255, 255/255, 255/255, 0.15)
                    }

                    contentItem: Text {
                        leftPadding: 12
                        text: protocolFilterCombo.displayText
                        font.pixelSize: 12
                        color: "#FFFFFF"
                        verticalAlignment: Text.AlignVCenter
                    }
                }

            Item { Layout.fillWidth: true }

            // 刷新服务器列表按钮
            Rectangle {
                Layout.preferredWidth: 36
                Layout.preferredHeight: 36
                radius: 8
                color: mouseArea1.containsMouse ? (isDarkMode ? "#3D3D3D" : "#E8E8E8") : "transparent"
                opacity: isRefreshing ? 0.5 : 1.0

                Behavior on color {
                    ColorAnimation { duration: 150 }
                }

                IconSymbol {
                    id: refreshIcon
                    anchors.centerIn: parent
                    icon: "refresh"
                    size: 20
                    color: isDarkMode ? "#CCCCCC" : "#555555"
                }

                MouseArea {
                    id: mouseArea1
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: !isRefreshing && typeof subscriptionManager !== 'undefined' && subscriptionManager
                    onClicked: {
                        triggerManualRefresh()
                    }
                }

                ToolTip.visible: mouseArea1.containsMouse
                ToolTip.text: qsTr("Refresh server list")
                ToolTip.delay: 500

                // 旋转动画（刷新时）
                RotationAnimation on rotation {
                    from: 0
                    to: 360
                    duration: 1000
                    running: isRefreshing
                    loops: Animation.Infinite
                }
            }

            // 按延迟排序按钮
            Rectangle {
                Layout.preferredWidth: 36
                Layout.preferredHeight: 36
                radius: 8
                color: mouseArea2.containsMouse ? (isDarkMode ? "#3D3D3D" : "#E8E8E8") : "transparent"

                Behavior on color {
                    ColorAnimation { duration: 150 }
                }

                IconSymbol {
                    anchors.centerIn: parent
                    icon: "timer"
                    size: 20
                    color: isDarkMode ? "#CCCCCC" : "#555555"
                }

                MouseArea {
                    id: mouseArea2
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: isInitialized && serverListViewModel !== null
                    onClicked: {
                        if (isInitialized && serverListViewModel) {
                            serverListViewModel.sortByLatency()
                        } else {
                        }
                    }
                }

                ToolTip.visible: mouseArea2.containsMouse
                ToolTip.text: qsTr("Sort by latency")
                ToolTip.delay: 500
            }

            // 按名称排序按钮
            Rectangle {
                Layout.preferredWidth: 36
                Layout.preferredHeight: 36
                radius: 8
                color: mouseArea3.containsMouse ? (isDarkMode ? "#3D3D3D" : "#E8E8E8") : "transparent"

                Behavior on color {
                    ColorAnimation { duration: 150 }
                }

                Label {
                    anchors.centerIn: parent
                    text: "A↓"
                    font.pixelSize: 16
                    font.weight: Font.Medium
                    color: isDarkMode ? "#CCCCCC" : "#555555"
                }

                MouseArea {
                    id: mouseArea3
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: isInitialized && serverListViewModel !== null
                    onClicked: {
                        if (isInitialized && serverListViewModel) {
                            serverListViewModel.sortByName()
                        }
                    }
                }

                ToolTip.visible: mouseArea3.containsMouse
                ToolTip.text: qsTr("Sort by name")
                ToolTip.delay: 500
            }

            // 测试延时按钮
            Rectangle {
                Layout.preferredWidth: 36
                Layout.preferredHeight: 36
                radius: 8
                color: mouseArea4.containsMouse ? (isDarkMode ? "#3D3D3D" : "#E8E8E8") : "transparent"
                opacity: (serverListViewModel && serverListViewModel.isBatchTesting) ? 0.5 : 1.0

                Behavior on color {
                    ColorAnimation { duration: 150 }
                }

                Label {
                    anchors.centerIn: parent
                    text: "◎"
                    font.pixelSize: 20
                    color: isDarkMode ? "#CCCCCC" : "#555555"
                }

                MouseArea {
                    id: mouseArea4
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: isInitialized && serverListViewModel !== null
                    onClicked: {
                        if (isInitialized && serverListViewModel) {
                            if (serverListViewModel.isBatchTesting) {
                                serverListViewModel.cancelBatchTest()
                            } else {
                                serverListViewModel.testAllServersLatency()
                            }
                        }
                    }
                }

                ToolTip.visible: mouseArea4.containsMouse
                ToolTip.text: "测试延时"
                ToolTip.delay: 500

                // 测速时的旋转动画
                RotationAnimation on rotation {
                    from: 0
                    to: 360
                    duration: 2000
                    running: serverListViewModel && serverListViewModel.isBatchTesting
                    loops: Animation.Infinite
                }
            }

            // 测试网速按钮（批量吞吐量测试）
            Rectangle {
                Layout.preferredWidth: 36
                Layout.preferredHeight: 36
                radius: 8
                color: mouseArea5.containsMouse ? (isDarkMode ? "#3D3D3D" : "#E8E8E8") : "transparent"
                opacity: isBatchThroughputTesting ? 0.5 : 1.0

                Behavior on color {
                    ColorAnimation { duration: 150 }
                }

                IconSymbol {
                    anchors.centerIn: parent
                    icon: "speed"
                    size: 18
                    color: isDarkMode ? "#CCCCCC" : "#555555"
                }

                MouseArea {
                    id: mouseArea5
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    enabled: isInitialized && serverListViewModel !== null && !isBatchThroughputTesting && throughputTestingServerId === ""
                    onClicked: {
                        startBatchThroughputTest()
                    }
                }

                ToolTip.visible: mouseArea5.containsMouse
                ToolTip.text: qsTr("Test All Speed")
                ToolTip.delay: 500

                // 测速时的旋转动画
                RotationAnimation on rotation {
                    from: 0
                    to: 360
                    duration: 2000
                    running: isBatchThroughputTesting
                    loops: Animation.Infinite
                }
            }

            // 测试进度指示器
            Text {
                visible: (serverListViewModel && serverListViewModel.isBatchTesting) || isBatchThroughputTesting
                text: {
                    if (isBatchThroughputTesting) {
                        return qsTr("Speed") + " " + (batchThroughputIndex + 1) + "/" + batchThroughputTotal
                    }
                    return serverListViewModel ? serverListViewModel.testingProgressText : ""
                }
                color: Theme.colors.textSecondary
                font.pixelSize: 13
                Layout.leftMargin: 10
                Layout.alignment: Qt.AlignVCenter
            }

            }
        }

        // Empty State
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.alignment: Qt.AlignCenter
            spacing: 20
            visible: serverCount === 0 && !isManuallyUpdating

            Label {
                text: "📭"
                font.pixelSize: 64
                Layout.alignment: Qt.AlignHCenter
            }
            Label {
                text: qsTr("No Servers Available")
                font.pixelSize: 20
                font.bold: true
                color: isDarkMode ? "white" : "#333333"
                Layout.alignment: Qt.AlignHCenter
            }
            Label {
                text: (typeof subscriptionManager !== 'undefined' && subscriptionManager && subscriptionManager.subscriptionCount > 0) ?
                    qsTr("Click 'Refresh' button above to load servers") :
                    qsTr("Please add a subscription first")
                font.pixelSize: 14
                color: isDarkMode ? "#CCCCCC" : "#666666"
                Layout.alignment: Qt.AlignHCenter
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                Layout.maximumWidth: 350
            }
            RowLayout {
                Layout.alignment: Qt.AlignHCenter
                spacing: 15
                CustomButton {
                    text: qsTr("Go to Subscriptions")
                    Layout.preferredWidth: 140
                    Layout.preferredHeight: 40
                    variant: (typeof subscriptionManager !== 'undefined' && subscriptionManager && subscriptionManager.subscriptionCount > 0) ? "default" : "primary"
                    onClicked: {
                        if (mainWindow) {
                            mainWindow.navigateTo("store", "pages/StorePage.qml")
                        }
                    }
                }
            }
        }

        // Loading State
        ColumnLayout {
            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.alignment: Qt.AlignCenter
            spacing: 20
            visible: isManuallyUpdating && serverCount === 0

            Label {
                text: "⏳"
                font.pixelSize: 64
                Layout.alignment: Qt.AlignHCenter
            }
            Label {
                text: qsTr("Loading servers...")
                font.pixelSize: 20
                font.bold: true
                color: isDarkMode ? "white" : "#333333"
                Layout.alignment: Qt.AlignHCenter
            }
            Label {
                text: qsTr("Please wait a moment")
                font.pixelSize: 14
                color: isDarkMode ? "#CCCCCC" : "#666666"
                Layout.alignment: Qt.AlignHCenter
            }
        }
        
        // Server List View - 使用分组显示
        ScrollView {
            id: serverScrollView
            Layout.fillWidth: true
            Layout.fillHeight: true
            visible: serverCount > 0
            clip: true
            ScrollBar.horizontal.policy: ScrollBar.AlwaysOff

            ColumnLayout {
                width: parent.width
                spacing: 12

                Repeater {
                    id: continentRepeater
                    // 按距离排序大洲，只显示有服务器的大洲
                    model: {
                        var sortedContinents = serverListViewModel ? serverListViewModel.getSortedContinents() : []
                        var existingContinents = Object.keys(groupedServers)
                        var result = []
                        // 按排序顺序添加存在的大洲
                        for (var i = 0; i < sortedContinents.length; i++) {
                            if (existingContinents.indexOf(sortedContinents[i]) >= 0) {
                                result.push(sortedContinents[i])
                            }
                        }
                        // 添加排序列表中没有的大洲（如"其他"）
                        for (var j = 0; j < existingContinents.length; j++) {
                            if (result.indexOf(existingContinents[j]) < 0) {
                                result.push(existingContinents[j])
                            }
                        }
                        return result
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 6

                        // 地区分组标题
                        Rectangle {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 40
                            color: Theme.colors.surface
                            radius: 6

                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 12
                                anchors.rightMargin: 12
                                spacing: 10

                                // 大洲图标
                                Label {
                                    text: CountryHelper.getContinentIcon(modelData)
                                    font.pixelSize: 18
                                }

                                Label {
                                    text: {
                                        var country = modelData
                                        var count = groupedServers[country] ? groupedServers[country].length : 0
                                        var displayName = CountryHelper.getContinentName(country)
                                        return displayName + " (" + count + ")"
                                    }
                                    font.pixelSize: 14
                                    font.bold: true
                                    color: isDarkMode ? "#FFFFFF" : "#212121"
                                }

                                Item { Layout.fillWidth: true }

                                Label {
                                    text: expandedGroups[modelData] ? "▼" : "▶"
                                    font.pixelSize: 12
                                    color: isDarkMode ? "#B0B0B0" : "#757575"
                                }
                            }

                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    var country = modelData
                                    var newExpanded = {}
                                    for (var key in expandedGroups) {
                                        newExpanded[key] = expandedGroups[key]
                                    }
                                    newExpanded[country] = !expandedGroups[country]
                                    expandedGroups = newExpanded
                                }
                            }
                        }

                        // 该地区的服务器列表
                        Repeater {
                            id: serverRepeater
                            model: expandedGroups[modelData] ? groupedServers[modelData] : []

                            Item {
                                id: serverCardWrapper
                                // 关键修复：检查modelData是否有效，防止访问已删除的Server对象
                                visible: modelData !== null && modelData !== undefined &&
                                         (modelData.id !== undefined && modelData.id !== null && modelData.id !== "")
                                enabled: modelData !== null && modelData !== undefined
                                Layout.fillWidth: true
                                // 根据是否有测速结果动态调整高度
                                Layout.preferredHeight: {
                                    // 检查是否有测速结果
                                    return 90  // 固定高度
                                }
                                clip: true

                                // 平台检测
                                readonly property bool isMobile: Qt.platform.os === "android" ||
                                    Qt.platform.os === "ios" ||
                                    Qt.platform.os === "winrt"
                                readonly property bool isDesktop: !isMobile

                                // 滑动相关属性
                                property real swipeOffset: 0
                                property bool isSwipedOpen: false
                                property real actionButtonsWidth: 140  // 连接+复制按钮的总宽度

                                // 背景层：操作按钮（移动端左滑显示）
                                Rectangle {
                                    id: actionButtonsBackground
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    width: serverCardWrapper.actionButtonsWidth
                                    color: isDarkMode ? "#2C2C2C" : "#F5F5F5"
                                    visible: serverCardWrapper.isMobile

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.margins: 8
                                        spacing: 8

                                        // 连接/断开按钮
                                        CustomButton {
                                            text: {
                                                if (modelData && modelData.id === (currentServer ? currentServer.id : "")) {
                                                    if (safeIsConnected()) {
                                                        return qsTr("Off")
                                                    } else if (safeIsConnecting()) {
                                                        return "..."
                                                    }
                                                }
                                                return qsTr("Go")
                                            }
                                            Layout.fillWidth: true
                                            Layout.fillHeight: true
                                            variant: (modelData && modelData.id === (currentServer ? currentServer.id : "") &&
                                                     safeIsConnected()) ? "error" : "primary"
                                            enabled: modelData && !safeIsConnecting()
                                            onClicked: {
                                                if (!serverListViewModel || !modelData || !modelData.id) return
                                                var serverId = modelData.id
                                                var serverObj = modelData

                                                // 关闭滑动菜单
                                                serverCardWrapper.isSwipedOpen = false
                                                serverCardWrapper.swipeOffset = 0

                                                if (serverId === (currentServer ? currentServer.id : "") && safeIsConnected()) {
                                                    // 如果已连接，断开连接
                                                    serverListViewModel.disconnect()
                                                } else {
                                                    // 通过ID获取C++ Server对象，不能直接传JS对象
                                                    var cppServer = getServerById(serverId)
                                                    if (!cppServer) return

                                                    // 选中服务器
                                                    handleServerSelection(serverObj)

                                                    // 跳转到连接页面
                                                    if (mainWindow && typeof mainWindow.navigateTo === 'function') {
                                                        mainWindow.navigateTo("connection", "pages/ConnectionPage.qml")
                                                    }

                                                    // 连接服务器（传C++对象）
                                                    serverListViewModel.connectToServer(cppServer)
                                                }
                                            }
                                        }

                                        // 测速按钮（吞吐量测速）
                                        CustomButton {
                                            text: qsTr("Test")
                                            Layout.fillWidth: true
                                            Layout.fillHeight: true
                                            variant: "default"
                                            onClicked: {
                                                serverCardWrapper.isSwipedOpen = false
                                                serverCardWrapper.swipeOffset = 0

                                                if (!modelData || !modelData.id || !serverListViewModel) return

                                                var serverId = modelData.id
                                                var serverName = modelData.name || modelData.address || ""
                                                // 调用新的吞吐量测试函数（会自动连接并测速）
                                                startThroughputTest(serverId, serverName)
                                            }
                                        }
                                    }
                                }

                                // 前景层：服务器信息卡片（可滑动）
                                Rectangle {
                                    id: serverCard
                                    y: 0
                                    width: parent.width
                                    height: parent.height
                                    x: serverCardWrapper.isMobile ? -serverCardWrapper.swipeOffset : 0
                                    color: {
                                        var isCurrentServer = modelData && modelData.id === (currentServer ? currentServer.id : "")
                                        if (isCurrentServer) {
                                            // 移动端使用橙色背景，桌面端使用蓝色背景
                                            if (serverCardWrapper.isMobile) {
                                                return isDarkMode ? "#8B5A00" : "#FFF3E0"  // 橙色背景
                                            } else {
                                                return isDarkMode ? "#2D4A7C" : "#E3F2FD"  // 蓝色背景
                                            }
                                        }
                                        return isDarkMode ? "#1E1E1E" : "#FFFFFF"
                                    }
                                    radius: 8
                                    border.color: {
                                        var isCurrentServer = modelData && modelData.id === (currentServer ? currentServer.id : "")
                                        if (isCurrentServer) {
                                            if (serverCardWrapper.isMobile) {
                                                return isDarkMode ? "#FF9800" : "#FF9800"  // 橙色边框
                                            } else {
                                                return isDarkMode ? "#4A90E2" : "#2196F3"  // 蓝色边框
                                            }
                                        }
                                        return isDarkMode ? "#333333" : "#E0E0E0"
                                    }
                                    border.width: (modelData && modelData.id === (currentServer ? currentServer.id : "")) ? 2 : 1

                                    property bool isHovered: true  // 始终显示按钮，不需要鼠标悬停

                                    // 仅在释放时动画（自动贴合），滑动时立即跟随
                                    Behavior on x {
                                        enabled: serverCardWrapper.isMobile && !serverCardMouseArea.pressed
                                        NumberAnimation { duration: 150; easing.type: Easing.OutCubic }
                                    }

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: 15
                                    anchors.rightMargin: 15
                                    spacing: 12
                                    enabled: serverCard.enabled

                                    // 国旗/图标
                                    FlagIcon {
                                        Layout.preferredWidth: 48
                                        Layout.preferredHeight: 48
                                        Layout.alignment: Qt.AlignVCenter
                                        size: 48
                                        countryCode: modelData ? (modelData.countryCode || "") : ""
                                    }

                                    // 服务器信息
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        Layout.alignment: Qt.AlignVCenter
                                        spacing: 4

                                        // 第一行：名称 + 协议标签 + 收藏
                                        RowLayout {
                                            spacing: 8
                                            Layout.fillWidth: true

                                            Label {
                                                text: modelData ? (modelData.name || "Unknown") : "Unknown"
                                                color: isDarkMode ? "#FFFFFF" : "#212121"
                                                font.pixelSize: 15
                                                font.bold: true
                                                elide: Text.ElideRight
                                                Layout.maximumWidth: 200
                                            }

                                            // 协议标签
                                            Rectangle {
                                                visible: modelData && modelData.protocol
                                                color: (modelData && modelData.protocol) ? getProtocolColor(modelData.protocol) : "#666666"
                                                radius: 3
                                                Layout.preferredWidth: protocolText.implicitWidth + 10
                                                Layout.preferredHeight: 18

                                                Label {
                                                    id: protocolText
                                                    anchors.centerIn: parent
                                                    text: (modelData && modelData.protocol) ? modelData.protocol.toUpperCase() : ""
                                                    color: "white"
                                                    font.pixelSize: 10
                                                    font.bold: true
                                                }
                                            }

                                            // 收藏标记
                                            Label {
                                                text: "★"
                                                color: Theme.colors.accentGold
                                                font.pixelSize: 14
                                                visible: modelData && modelData.isFavorite === true
                                            }

                                            Item { Layout.fillWidth: true }
                                        }

                                        // 第二行：位置信息（隐藏URL地址）
                                        RowLayout {
                                            spacing: 6
                                            Layout.fillWidth: true
                                            visible: modelData && modelData.location

                                            Label {
                                                text: "📍"
                                                font.pixelSize: 11
                                            }

                                            Label {
                                                text: (modelData && modelData.location) ? modelData.location : ""
                                                color: isDarkMode ? "#B0B0B0" : "#757575"
                                                font.pixelSize: 12
                                                elide: Text.ElideRight
                                                Layout.fillWidth: true
                                            }
                                        }

                                        // 第三行：附加信息（带宽 + 负载 + 延时）
                                        RowLayout {
                                            spacing: 12
                                            Layout.fillWidth: true

                                            // 带宽信息
                                            RowLayout {
                                                spacing: 4
                                                visible: modelData && modelData.bandwidth

                                                IconSymbol {
                                                    icon: "speed"
                                                    size: 11
                                                    color: Theme.colors.textSecondary
                                                }

                                                Label {
                                                    text: (modelData && modelData.bandwidth) ? modelData.bandwidth : ""
                                                    color: isDarkMode ? "#90A4AE" : "#78909C"
                                                    font.pixelSize: 11
                                                }
                                            }

                                            // TODO: 落地IP信息（后续完善，需要解析域名获取真实IP）
                                            // RowLayout {
                                            //     spacing: 4
                                            //     visible: modelData && modelData.resolvedIP
                                            //     Label { text: "🌐"; font.pixelSize: 11 }
                                            //     Label { text: modelData ? (modelData.resolvedIP || "") : ""; color: isDarkMode ? "#90A4AE" : "#78909C"; font.pixelSize: 11 }
                                            // }

                                            // 延时信息
                                            RowLayout {
                                                spacing: 4
                                                visible: modelData && (modelData.latency !== undefined || modelData.isTestingSpeed)

                                                // 测速时显示旋转图标
                                                IconSymbol {
                                                    visible: modelData && modelData.isTestingSpeed
                                                    icon: "refresh"
                                                    size: 11
                                                    color: Theme.colors.textSecondary

                                                    RotationAnimation on rotation {
                                                        running: modelData && modelData.isTestingSpeed
                                                        from: 0
                                                        to: 360
                                                        duration: 1000
                                                        loops: Animation.Infinite
                                                    }
                                                }

                                                Label {
                                                    visible: modelData && modelData.isTestingSpeed
                                                    text: qsTr("Testing...")
                                                    color: isDarkMode ? "#90A4AE" : "#78909C"
                                                    font.pixelSize: 11
                                                }

                                                // 延时状态圆点（非测速时显示）
                                                Rectangle {
                                                    visible: modelData && !modelData.isTestingSpeed
                                                    width: 8
                                                    height: 8
                                                    radius: 4
                                                    color: {
                                                        if (!modelData || modelData.latency === undefined || modelData.latency < 0) return "#9E9E9E"  // 灰色-未测试
                                                        if (modelData.latency === 0) return "#9E9E9E"  // 灰色-超时
                                                        if (modelData.latency < 100) return "#4CAF50"  // 绿色-优秀
                                                        if (modelData.latency < 200) return "#FFC107"  // 黄色-良好
                                                        if (modelData.latency < 300) return "#FF9800"  // 橙色-一般
                                                        return "#F44336"  // 红色-较差
                                                    }
                                                }

                                                // 延时数值（非测速时显示）
                                                Label {
                                                    visible: modelData && !modelData.isTestingSpeed
                                                    text: {
                                                        if (!modelData || modelData.latency === undefined) return "--"
                                                        if (modelData.latency < 0) return "--"
                                                        if (modelData.latency === 0) return qsTr("Timeout")
                                                        return modelData.latency + " ms"
                                                    }
                                                    color: {
                                                        if (!modelData || modelData.latency === undefined) return isDarkMode ? "#90A4AE" : "#78909C"
                                                        if (modelData.latency < 0) return isDarkMode ? "#90A4AE" : "#78909C"
                                                        if (modelData.latency === 0) return "#9E9E9E"
                                                        if (modelData.latency < 100) return "#4CAF50"
                                                        if (modelData.latency < 200) return "#FFC107"
                                                        if (modelData.latency < 300) return "#FF9800"
                                                        return "#F44336"
                                                    }
                                                    font.pixelSize: 11
                                                    font.bold: modelData && modelData.latency > 0
                                                }
                                            }

                                            Item { Layout.fillWidth: true }
                                        }

                                        // 第四行：测速结果显示（IP、ASN、速度）- 单独一行显示
                                        RowLayout {
                                            id: speedTestResultRow
                                            Layout.fillWidth: true
                                            spacing: 12

                                            // 使用唯一的 serverId 来获取测速结果，避免数据串
                                            property string serverId: modelData ? (modelData.id || "") : ""
                                            // 从 ViewModel 获取该服务器的测试结果（通过 serverId 精确匹配）
                                            property var vmSpeedResults: serverListViewModel ? serverListViewModel.speedTestResults : ({})
                                            property var vmResult: (vmSpeedResults && serverId !== "" && vmSpeedResults[serverId]) ? vmSpeedResults[serverId] : ({})
                                            // 判断是否有测速结果
                                            property bool hasResult: vmResult && ((vmResult.speed || "") !== "" || (vmResult.ip || "") !== "" || (vmResult.ipInfo || "") !== "")
                                            // 直接从 ViewModel 获取结果（按 serverId 精确匹配，不使用 lastTested 属性避免数据串）
                                            property string resultIp: vmResult.ip || ""
                                            property string resultIpInfo: vmResult.ipInfo || ""
                                            property string resultSpeed: vmResult.speed || ""

                                            visible: hasResult && (resultIp !== "" || resultSpeed !== "" || resultIpInfo !== "")

                                            // IP 地址
                                            RowLayout {
                                                visible: speedTestResultRow.resultIp !== ""
                                                spacing: 4
                                                Label {
                                                    text: "⊙"
                                                    color: "#4CAF50"
                                                    font.pixelSize: 11
                                                }
                                                Label {
                                                    text: speedTestResultRow.resultIp
                                                    color: isDarkMode ? "#A5D6A7" : "#388E3C"
                                                    font.pixelSize: 11
                                                }
                                            }

                                            // ASN 和 ISP 信息
                                            RowLayout {
                                                visible: speedTestResultRow.resultIpInfo !== ""
                                                spacing: 4
                                                Label {
                                                    text: "◈"
                                                    color: "#FF9800"
                                                    font.pixelSize: 11
                                                }
                                                Label {
                                                    text: speedTestResultRow.resultIpInfo
                                                    color: isDarkMode ? "#FFE082" : "#F57C00"
                                                    font.pixelSize: 11
                                                    Layout.maximumWidth: 400
                                                    wrapMode: Text.NoWrap
                                                }
                                            }

                                            // 下载速度 - 更醒目的显示
                                            RowLayout {
                                                visible: speedTestResultRow.resultSpeed !== ""
                                                spacing: 4
                                                Label {
                                                    text: "↓"
                                                    color: "#2196F3"
                                                    font.pixelSize: 12
                                                    font.bold: true
                                                }
                                                Label {
                                                    text: speedTestResultRow.resultSpeed
                                                    color: "#2196F3"
                                                    font.pixelSize: 12
                                                    font.bold: true
                                                }
                                            }

                                            Item { Layout.fillWidth: true }
                                        }
                                    }

                                    // Pro标记
                                    Rectangle {
                                        visible: modelData && modelData.isPro === true
                                        color: Theme.colors.accentGold
                                        radius: 4
                                        Layout.preferredWidth: 45
                                        Layout.preferredHeight: 22
                                        Layout.alignment: Qt.AlignVCenter

                                        Label {
                                            text: "PRO"
                                            color: "#000000"
                                            font.pixelSize: 11
                                            font.bold: true
                                            anchors.centerIn: parent
                                        }
                                    }

                                    // 连接按钮（桌面端始终显示）
                                    CustomButton {
                                        id: connectBtn
                                        visible: serverCardWrapper.isDesktop && modelData
                                        // 判断当前行是否正在测速
                                        readonly property bool isThisServerSpeedTesting: modelData && modelData.id && speedTestingServerId === modelData.id
                                        // 判断是否是当前正在连接/已连接的服务器
                                        readonly property string thisServerId: modelData ? (modelData.id || "") : ""
                                        readonly property string currentServId: currentServer ? (currentServer.id || currentServer.serverId || "") : ""
                                        readonly property bool isThisServerCurrent: thisServerId !== "" && thisServerId === currentServId
                                        readonly property bool isCurrentConnected: isThisServerCurrent && safeIsConnected()
                                        readonly property bool isThisServerConnecting: isThisServerCurrent && safeIsConnecting()
                                        text: {
                                            // 只有正在连接到这个服务器时才显示"连接中..."
                                            if (isThisServerConnecting) {
                                                return "连接中..."
                                            }
                                            // 如果是当前服务器且已连接（包括测速中），显示"断开"
                                            if (isCurrentConnected || isThisServerSpeedTesting) {
                                                return "断开"
                                            }
                                            return "连接"
                                        }
                                        Layout.preferredWidth: isThisServerConnecting ? 80 : 60
                                        Layout.preferredHeight: 32
                                        Layout.alignment: Qt.AlignVCenter
                                        // 测速中或已连接时显示红色断开按钮
                                        variant: (isCurrentConnected || isThisServerSpeedTesting) ? "error" : "primary"
                                        font.pixelSize: 12
                                        // 只有正在连接的那一行禁用，其他行正常
                                        enabled: {
                                            if (!modelData) return false
                                            // 如果是正在测速的服务器，保持启用（显示断开按钮）
                                            if (isThisServerSpeedTesting) return true
                                            // 如果是正在连接到这个服务器，禁用
                                            if (isThisServerConnecting) return false
                                            return true
                                        }
                                        onClicked: {
                                            if (!serverListViewModel || !modelData || !modelData.id) return
                                            var serverId = modelData.id
                                            var currentId = currentServer ? currentServer.id : ""
                                            var isConnected = safeIsConnected()

                                            // 如果正在测速这个服务器，取消测速并断开
                                            if (isThisServerSpeedTesting) {
                                                // 停止测速相关计时器
                                                ipWaitTimer.stop()
                                                speedTestTimer.stop()
                                                isDownloading = false
                                                waitingForIpInfo = false
                                                speedTestingServerId = ""
                                                serverListViewModel.disconnect()
                                                return
                                            }

                                            // 如果是当前服务器且已连接，执行断开操作
                                            if (serverId === currentId && isConnected) {
                                                serverListViewModel.disconnect()
                                                return
                                            }

                                            // 获取真正的C++ Server对象
                                            var realServerObj = getServerById(serverId)
                                            if (!realServerObj) {
                                                return
                                            }

                                            // 选中服务器
                                            handleServerSelection(modelData)

                                            // 如果已连接到其他服务器，先断开再连接
                                            if (isConnected && serverId !== currentId) {
                                                serverListViewModel.disconnect()
                                            }

                                            // 跳转到连接页面
                                            if (mainWindow && typeof mainWindow.navigateTo === 'function') {
                                                mainWindow.navigateTo("connection", "pages/ConnectionPage.qml")
                                            }

                                            // 连接服务器 (使用真正的C++对象)
                                            serverListViewModel.connectToServer(realServerObj)
                                        }
                                    }

                                    // 测速按钮（桌面端始终显示）- 下载测速
                                    CustomButton {
                                        id: speedTestBtn
                                        visible: serverCardWrapper.isDesktop && modelData

                                        // 获取当前服务器ID（统一使用 modelData.id，与 groupServersByCountry 保持一致）
                                        readonly property string currentServerId: modelData ? (modelData.id || "") : ""
                                        // 判断当前行是否正在测速
                                        readonly property bool isThisServerTesting: currentServerId !== "" && speedTestingServerId !== "" && speedTestingServerId === currentServerId

                                        text: isThisServerTesting ? "正在测速" : "测速"
                                        // 正在测速时禁用该按钮
                                        enabled: modelData && !isThisServerTesting
                                        Layout.preferredWidth: isThisServerTesting ? 80 : 60
                                        Layout.preferredHeight: 32
                                        Layout.alignment: Qt.AlignVCenter
                                        variant: isThisServerTesting ? "primary" : "default"
                                        font.pixelSize: 12
                                        onClicked: {
                                            if (typeof serverListViewModel === 'undefined') {
                                                return
                                            }

                                            var serverId = currentServerId
                                            if (!serverId) return

                                            // 获取真正的C++ Server对象
                                            var realServerObj = getServerById(serverId)
                                            if (!realServerObj) {
                                                return
                                            }

                                            // 设置测速状态为当前服务器ID
                                            speedTestingServerId = serverId

                                            // 选中服务器
                                            handleServerSelection(modelData)

                                            // 如果VPN已连接，先断开
                                            if (safeIsConnected()) {
                                                serverListViewModel.disconnect()
                                            }

                                            // 跳转到连接页面
                                            if (mainWindow && typeof mainWindow.navigateTo === 'function') {
                                                mainWindow.navigateTo("connection", "pages/ConnectionPage.qml")
                                            }

                                            // 连接到目标服务器进行测速
                                            serverListViewModel.connectToServer(realServerObj)
                                        }
                                    }
                                }

                                // 点击和Hover检测区域（移动端+桌面端）
                                MouseArea {
                                    id: serverCardMouseArea
                                    anchors.fill: parent
                                    z: -1  // 放在按钮下方，让按钮可以接收点击
                                    hoverEnabled: serverCardWrapper.isDesktop
                                    enabled: serverCard.enabled
                                    propagateComposedEvents: true  // 允许事件传递到下层的按钮
                                    cursorShape: serverCardWrapper.isDesktop ? Qt.PointingHandCursor : Qt.ArrowCursor

                                    // 桌面端的hover效果
                                    onEntered: {
                                        if (serverCardWrapper.isDesktop && modelData && modelData.id !== undefined && modelData.id !== null) {
                                            serverCard.isHovered = true
                                            serverCard.border.color = isDarkMode ? "#5A9DE5" : "#42A5F5"
                                            serverCard.border.width = 2
                                        }
                                    }
                                    onExited: {
                                        if (serverCardWrapper.isDesktop) {
                                            serverCard.isHovered = false
                                            if (modelData && modelData.id !== undefined && modelData.id !== null) {
                                                serverCard.border.color = modelData.id === (currentServer ? currentServer.id : "") ?
                                                    (isDarkMode ? "#4A90E2" : "#2196F3") :
                                                    (isDarkMode ? "#333333" : "#E0E0E0")
                                                serverCard.border.width = 1
                                            }
                                        }
                                    }

                                    // 桌面端点击处理
                                    onClicked: function(mouse) {
                                        // 检查是否点击了按钮区域
                                        if (serverCardWrapper.isDesktop) {
                                            // 检查点击位置是否在右侧按钮区域（约占卡片右侧200像素）
                                            var clickX = mouse.x
                                            var cardWidth = serverCard.width
                                            var buttonAreaWidth = 200  // 连接按钮+测速按钮+菜单按钮的大致宽度

                                            // 如果点击在右侧按钮区域内，不处理选择，让事件传递给按钮
                                            if (clickX > cardWidth - buttonAreaWidth) {
                                                mouse.accepted = false
                                                return
                                            }

                                            // 否则处理服务器选择
                                            if (modelData && modelData.id) {
                                                handleServerSelection(modelData)
                                            }
                                        }
                                        mouse.accepted = true
                                    }

                                    // 移动端滑动手势支持
                                    property real startX: 0
                                    property real startY: 0
                                    property real startSwipeOffset: 0
                                    property bool isHorizontalSwipe: false
                                    property bool swipeDirectionDetermined: false

                                    onPressed: function(mouse) {
                                        if (serverCardWrapper.isMobile) {
                                            startX = mouse.x
                                            startY = mouse.y
                                            startSwipeOffset = serverCardWrapper.swipeOffset
                                            isHorizontalSwipe = false
                                            swipeDirectionDetermined = false
                                        }
                                    }

                                    onPositionChanged: function(mouse) {
                                        if (serverCardWrapper.isMobile && pressed) {
                                            var deltaX = Math.abs(mouse.x - startX)
                                            var deltaY = Math.abs(mouse.y - startY)

                                            // 判断滑动方向（只判断一次）
                                            if (!swipeDirectionDetermined && (deltaX > 10 || deltaY > 10)) {
                                                swipeDirectionDetermined = true
                                                isHorizontalSwipe = deltaX > deltaY

                                                if (isHorizontalSwipe) {
                                                    // 水平滑动：检测左滑还是右滑，立即切换
                                                    var swipeDirection = mouse.x - startX  // 正数=右滑，负数=左滑

                                                    if (swipeDirection < 0) {
                                                        // 左滑：立即完全打开
                                                        serverCardWrapper.swipeOffset = serverCardWrapper.actionButtonsWidth
                                                        serverCardWrapper.isSwipedOpen = true
                                                    } else {
                                                        // 右滑：立即完全关闭
                                                        serverCardWrapper.swipeOffset = 0
                                                        serverCardWrapper.isSwipedOpen = false
                                                    }
                                                } else {
                                                    // 垂直滑动：关闭已打开的菜单
                                                    if (serverCardWrapper.isSwipedOpen) {
                                                        serverCardWrapper.swipeOffset = 0
                                                        serverCardWrapper.isSwipedOpen = false
                                                    }
                                                }
                                            }
                                        }
                                    }

                                    onReleased: function(mouse) {
                                        if (serverCardWrapper.isMobile) {
                                            // 如果没有触发滑动判断（只是轻点），则选中服务器
                                            if (!swipeDirectionDetermined) {
                                                var deltaX = Math.abs(startX - mouse.x)
                                                var deltaY = Math.abs(startY - mouse.y)
                                                if (deltaX < 10 && deltaY < 10 && modelData && modelData.id) {
                                                    handleServerSelection(modelData)
                                                }
                                            }

                                            // 重置状态
                                            isHorizontalSwipe = false
                                            swipeDirectionDetermined = false
                                        }
                                    }
                                }

                                // 按压动画
                                scale: serverCard.isHovered ? 1.0 : 0.98
                                Behavior on scale {
                                    NumberAnimation { duration: 150; easing.type: Easing.OutQuad }
                                }
                                }

                                // 移动端：点击其他区域时关闭已打开的滑动菜单
                                Connections {
                                    target: serverCardWrapper.isMobile ? serverCardWrapper.parent : null
                                    enabled: serverCardWrapper.isMobile && serverCardWrapper.isSwipedOpen

                                    function onPressed() {
                                        if (serverCardWrapper.isSwipedOpen) {
                                            serverCardWrapper.swipeOffset = 0
                                            serverCardWrapper.isSwipedOpen = false
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    function handleServerSelection(serverData) {
        if (!serverData || !serverData.id) {
            return
        }

        if (mainWindow && mainWindow.isAuthenticated) {
            if (vpnManager) {
                // 【关键修复】通过ID获取C++ Server对象，不要传递JavaScript对象
                var server = getServerById(serverData.id)
                if (server) {
                    try {
                        vpnManager.selectServer(server)
                        // 不调用connecting，selectServer会处理
                    } catch (e) {
                    }
                } else {
                }
            }
        } else if (mainWindow) {
            mainWindow.stackView.replace("pages/LoginPage.qml")
            mainWindow.currentPage = "login"
        }
    }

    // 根据协议返回对应颜色
    function getProtocolColor(protocol) {
        if (!protocol) return isDarkMode ? "#616161" : "#9E9E9E"

        var p = protocol.toLowerCase()
        switch(p) {
            case "vmess": return "#2196F3"      // 蓝色
            case "vless": return "#9C27B0"      // 紫色
            case "trojan": return "#F44336"     // 红色
            case "shadowsocks":
            case "ss": return "#FF9800"         // 橙色
            case "socks":
            case "socks5": return "#00BCD4"     // 青色
            case "http":
            case "https": return "#4CAF50"      // 绿色
            default: return isDarkMode ? "#616161" : "#9E9E9E"
        }
    }

    // 显示复制成功提示
    function showCopyToast(message) {
        copyToast.message = message
        copyToast.opacity = 1
        copyToastAnimation.restart()
    }

    // 复制成功提示框
    Rectangle {
        id: copyToast
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 80
        width: 200
        height: 48
        radius: Theme.radius.md
        color: Theme.colors.success
        opacity: 0
        visible: opacity > 0

        property string message: ""

        Label {
            anchors.centerIn: parent
            text: copyToast.message
            color: "white"
            font.pixelSize: Theme.typography.body2
            font.weight: Theme.typography.weightMedium
        }

        NumberAnimation on opacity {
            id: copyToastAnimation
            running: false
            from: 1
            to: 0
            duration: 2000
            easing.type: Easing.InOutQuad
        }
    }

    // ========== 吞吐量测速弹窗 ==========
    property string throughputTestingServerId: ""  // 正在测试吞吐量的服务器ID
    property string throughputTestServerName: ""   // 正在测试的服务器名称
    property bool throughputWaitingForConnection: false  // 是否在等待连接完成

    // 批量测速属性
    property var batchThroughputQueue: []  // 批量测速队列 [{id, name}, ...]
    property int batchThroughputIndex: 0   // 当前测试索引
    property int batchThroughputTotal: 0   // 总数
    property bool isBatchThroughputTesting: false  // 是否正在批量测试

    // 监听吞吐量测试完成信号
    Connections {
        target: serverListViewModel
        function onServerThroughputTestCompleted(server, speedMbps) {
            if (isBatchThroughputTesting) {
                // 批量测速模式：继续下一个
                batchThroughputIndex++
                if (batchThroughputIndex < batchThroughputTotal) {
                    // 还有更多服务器要测试
                    var nextServer = batchThroughputQueue[batchThroughputIndex]
                    throughputTestingServerId = nextServer.id
                    throughputTestServerName = nextServer.name
                    throughputWaitingForConnection = true

                    // 断开当前连接，连接下一个
                    if (safeIsConnected()) {
                        serverListViewModel.disconnect()
                    }

                    // 延迟连接下一个服务器
                    batchNextServerTimer.start()
                } else {
                    // 批量测速完成
                    throughputTestDialog.close()
                    throughputTestingServerId = ""
                    throughputTestServerName = ""
                    throughputWaitingForConnection = false
                    isBatchThroughputTesting = false
                    batchThroughputQueue = []
                    showCopyToast(qsTr("Batch test completed"))
                }
            } else {
                // 单个测速模式
                throughputTestDialog.close()
                throughputTestingServerId = ""
                throughputTestServerName = ""
                throughputWaitingForConnection = false

                // 显示结果提示
                if (speedMbps > 0) {
                    showCopyToast(qsTr("Speed: %1 Mbps").arg(speedMbps.toFixed(2)))
                } else {
                    showCopyToast(qsTr("Speed test failed"))
                }
            }
        }
    }

    // 批量测速：连接下一个服务器的定时器
    Timer {
        id: batchNextServerTimer
        interval: 500
        running: false
        repeat: false
        onTriggered: {
            if (batchThroughputIndex < batchThroughputTotal) {
                var nextServer = batchThroughputQueue[batchThroughputIndex]
                var realServerObj = getServerById(nextServer.id)
                if (realServerObj) {
                    handleServerSelection(realServerObj)
                    serverListViewModel.connectToServer(realServerObj)
                } else {
                    // 跳过无效服务器
                    batchThroughputIndex++
                    if (batchThroughputIndex < batchThroughputTotal) {
                        batchNextServerTimer.start()
                    }
                }
            }
        }
    }

    // 监听VPN连接状态变化，连接成功后开始测速
    Connections {
        target: vpnManager
        function onStateChanged() {
            if (throughputTestingServerId !== "" && throughputWaitingForConnection) {
                if (safeIsConnected()) {
                    throughputWaitingForConnection = false
                    // 连接成功，延迟一点开始测速
                    throughputTestDelayTimer.start()
                }
            }
        }
    }

    // 延迟启动测速的定时器（等待连接稳定）
    Timer {
        id: throughputTestDelayTimer
        interval: 1000  // 等待1秒让连接稳定
        running: false
        repeat: false
        onTriggered: {
            if (throughputTestingServerId !== "" && serverListViewModel) {
                serverListViewModel.testServerThroughput(throughputTestingServerId)
            }
        }
    }

    // 开始吞吐量测试的函数（单个服务器）
    function startThroughputTest(serverId, serverName) {
        isBatchThroughputTesting = false
        throughputTestingServerId = serverId
        throughputTestServerName = serverName
        throughputTestDialog.open()

        // 获取真正的C++ Server对象
        var realServerObj = getServerById(serverId)
        if (!realServerObj) {
            throughputTestDialog.close()
            showCopyToast(qsTr("Server not found"))
            return
        }

        // 先测试延迟
        serverListViewModel.testServerLatency(serverId)

        // 检查是否已经连接到此服务器
        var isConnectedToThis = safeIsConnected() && currentServer && currentServer.id === serverId

        if (isConnectedToThis) {
            // 已连接，直接测速
            if (serverListViewModel) {
                serverListViewModel.testServerThroughput(serverId)
            }
        } else {
            // 未连接，先连接再测速
            throughputWaitingForConnection = true

            // 如果已连接到其他服务器，先断开
            if (safeIsConnected()) {
                serverListViewModel.disconnect()
            }

            // 选中并连接服务器
            handleServerSelection(realServerObj)
            serverListViewModel.connectToServer(realServerObj)
        }
    }

    // 开始批量吞吐量测试
    function startBatchThroughputTest() {
        // 收集所有服务器
        var servers = []
        for (var i = 0; i < serversModel.count; i++) {
            var server = serversModel.get(i)
            if (server && server.serverId) {
                servers.push({id: server.serverId, name: server.serverName || server.serverAddress || ""})
            }
        }

        if (servers.length === 0) {
            showCopyToast(qsTr("No servers to test"))
            return
        }

        // 初始化批量测速状态
        batchThroughputQueue = servers
        batchThroughputIndex = 0
        batchThroughputTotal = servers.length
        isBatchThroughputTesting = true

        // 开始第一个
        var firstServer = servers[0]
        throughputTestingServerId = firstServer.id
        throughputTestServerName = firstServer.name
        throughputWaitingForConnection = true
        throughputTestDialog.open()

        // 先测试延迟
        serverListViewModel.testServerLatency(firstServer.id)

        // 断开当前连接（如果有）
        if (safeIsConnected()) {
            serverListViewModel.disconnect()
        }

        // 连接第一个服务器
        var realServerObj = getServerById(firstServer.id)
        if (realServerObj) {
            handleServerSelection(realServerObj)
            serverListViewModel.connectToServer(realServerObj)
        }
    }

    // 批量延时测试弹窗
    Dialog {
        id: latencyTestDialog
        anchors.centerIn: parent
        modal: true
        closePolicy: Popup.NoAutoClose

        width: Math.min(parent.width * 0.8, 300)
        padding: 24

        background: Rectangle {
            color: Theme.colors.surface
            radius: Theme.radius.lg
            border.color: Theme.colors.border
            border.width: 1
        }

        contentItem: ColumnLayout {
            spacing: 16

            // 标题
            Label {
                text: qsTr("Latency Testing")
                font.pixelSize: Theme.typography.h6
                font.weight: Theme.typography.weightBold
                color: Theme.colors.textPrimary
                Layout.alignment: Qt.AlignHCenter
            }

            // 进度文字
            Label {
                text: serverListViewModel ? serverListViewModel.testingProgressText : ""
                font.pixelSize: Theme.typography.body2
                color: Theme.colors.textSecondary
                Layout.alignment: Qt.AlignHCenter
            }

            // 加载动画
            BusyIndicator {
                running: latencyTestDialog.visible
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 48
                Layout.preferredHeight: 48
            }

            // 提示文字
            Label {
                text: qsTr("Testing latency...")
                font.pixelSize: Theme.typography.caption
                color: Theme.colors.textTertiary
                Layout.alignment: Qt.AlignHCenter
            }
        }
    }

    // 监听批量延时测试状态
    Connections {
        target: serverListViewModel
        function onIsBatchTestingChanged() {
            if (serverListViewModel && serverListViewModel.isBatchTesting) {
                latencyTestDialog.open()
            } else {
                latencyTestDialog.close()
            }
        }
    }

    // 吞吐量测试弹窗
    Dialog {
        id: throughputTestDialog
        anchors.centerIn: parent
        modal: true
        closePolicy: Popup.NoAutoClose  // 不允许点击外部关闭

        width: Math.min(parent.width * 0.8, 300)
        padding: 24

        background: Rectangle {
            color: Theme.colors.surface
            radius: Theme.radius.lg
            border.color: Theme.colors.border
            border.width: 1
        }

        contentItem: ColumnLayout {
            spacing: 16

            // 标题（批量模式显示进度）
            Label {
                text: isBatchThroughputTesting
                    ? qsTr("Speed Testing (%1/%2)").arg(batchThroughputIndex + 1).arg(batchThroughputTotal)
                    : qsTr("Speed Testing")
                font.pixelSize: Theme.typography.h6
                font.weight: Theme.typography.weightBold
                color: Theme.colors.textPrimary
                Layout.alignment: Qt.AlignHCenter
            }

            // 服务器名称
            Label {
                text: throughputTestServerName
                font.pixelSize: Theme.typography.body1
                font.weight: Theme.typography.weightMedium
                color: Theme.colors.textPrimary
                Layout.alignment: Qt.AlignHCenter
                wrapMode: Text.WordWrap
                horizontalAlignment: Text.AlignHCenter
                Layout.maximumWidth: parent.width - 20
            }

            // 加载动画
            BusyIndicator {
                running: throughputTestDialog.visible
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 48
                Layout.preferredHeight: 48
            }

            // 提示文字
            Label {
                text: throughputWaitingForConnection ? qsTr("Connecting...") : qsTr("Testing speed...")
                font.pixelSize: Theme.typography.caption
                color: Theme.colors.textTertiary
                Layout.alignment: Qt.AlignHCenter
            }

            // 取消按钮（仅批量模式显示）
            CustomButton {
                visible: isBatchThroughputTesting
                text: qsTr("Cancel")
                variant: "default"
                Layout.alignment: Qt.AlignHCenter
                Layout.preferredWidth: 100
                onClicked: {
                    // 断开VPN
                    if (safeIsConnected()) {
                        serverListViewModel.disconnect()
                    }
                    // 重置状态
                    throughputTestDialog.close()
                    throughputTestingServerId = ""
                    throughputTestServerName = ""
                    throughputWaitingForConnection = false
                    isBatchThroughputTesting = false
                    batchThroughputQueue = []
                    showCopyToast(qsTr("Test cancelled"))
                }
            }
        }
    }
}
