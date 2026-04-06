import QtQuick 2.15
import QtQuick.Controls 2.15
import QtQuick.Layouts 2.15
import JinGo 1.0
import "../js/qrcode.js" as QRCodeJS

Rectangle {
    id: inviteCard

    property bool isDarkMode: false
    property string inviteUrl: ""
    property string inviteCode: ""
    property int registeredCount: 0
    property int commissionRate: 0
    property int commissionBalance: 0
    property int totalCommission: 0
    property bool isLoading: false
    property bool hasData: false

    // 新增属性
    property bool isGenerating: false
    property var inviteDetails: []
    property bool isLoadingDetails: false
    property bool showDetails: false

    // 信号：供外部触发操作
    signal generateRequested()
    signal detailsRequested()

    readonly property string currencySymbol: {
        try {
            if (typeof systemConfigManager !== "undefined" && systemConfigManager &&
                systemConfigManager.currencySymbol) {
                return systemConfigManager.currencySymbol
            }
        } catch(e) {}
        return "¥"
    }

    readonly property int currencyUnit: {
        try {
            if (typeof systemConfigManager !== "undefined" && systemConfigManager &&
                systemConfigManager.currencyUnit > 0) {
                return systemConfigManager.currencyUnit
            }
        } catch(e) {}
        return 100
    }

    radius: Theme.radius.md
    color: Theme.colors.cardBackground
    border.color: Theme.colors.border
    border.width: 1
    implicitHeight: cardContent.implicitHeight + 32

    ColumnLayout {
        id: cardContent
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 16
        spacing: 12

        // 标题
        Label {
            text: qsTr("Invite & Earn")
            font.pixelSize: 16
            font.bold: true
            color: Theme.colors.textPrimary
        }

        // 加载中
        Label {
            visible: isLoading && !hasData
            text: qsTr("Loading...")
            font.pixelSize: 13
            color: Theme.colors.textSecondary
        }

        // 数据内容
        ColumnLayout {
            visible: hasData
            spacing: 12
            Layout.fillWidth: true

            // 生成邀请码按钮（无邀请码时显示）
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 36
                radius: Theme.radius.sm
                color: isGenerating ? Theme.colors.surfaceElevated : Theme.colors.primary
                visible: hasData && (!inviteCode || inviteCode.length === 0)
                opacity: isGenerating ? 0.7 : 1.0

                Label {
                    anchors.centerIn: parent
                    text: isGenerating ? qsTr("Generating...") : qsTr("Generate Invite Code")
                    font.pixelSize: 13
                    font.bold: true
                    color: isGenerating ? Theme.colors.textSecondary : "white"
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: isGenerating ? Qt.BusyCursor : Qt.PointingHandCursor
                    enabled: !isGenerating
                    onClicked: inviteCard.generateRequested()
                }
            }

            // 邀请链接行
            RowLayout {
                Layout.fillWidth: true
                spacing: 8

                Label {
                    text: inviteUrl
                    font.pixelSize: 12
                    color: Theme.colors.textSecondary
                    elide: Text.ElideMiddle
                    Layout.fillWidth: true
                }

                Rectangle {
                    width: copyRow.implicitWidth + 16
                    height: 28
                    radius: Theme.radius.sm
                    color: Theme.colors.surfaceElevated

                    RowLayout {
                        id: copyRow
                        anchors.centerIn: parent
                        spacing: 4

                        IconSymbol {
                            icon: "copy"
                            size: 14
                            color: Theme.colors.textSecondary
                        }

                        Label {
                            text: qsTr("Copy")
                            font.pixelSize: 12
                            color: Theme.colors.textSecondary
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            if (typeof clipboardHelper !== "undefined" && clipboardHelper) {
                                clipboardHelper.setText(inviteUrl)
                                copyTooltip.visible = true
                                copyTooltipTimer.restart()
                            }
                        }
                    }
                }
            }

            // 复制成功提示
            Label {
                id: copyTooltip
                visible: false
                text: qsTr("Copied!")
                font.pixelSize: 11
                color: Theme.colors.success
                Layout.alignment: Qt.AlignRight

                Timer {
                    id: copyTooltipTimer
                    interval: 2000
                    onTriggered: copyTooltip.visible = false
                }
            }

            // 二维码
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                width: 168
                height: 168
                color: isDarkMode ? "#2A2A2A" : "#FFFFFF"
                radius: 8

                Canvas {
                    id: qrCanvas
                    anchors.centerIn: parent
                    width: 152
                    height: 152

                    property string qrData: inviteUrl
                    property bool darkMode: isDarkMode

                    onQrDataChanged: {
                        if (qrData && qrData.length > 0) {
                            requestPaint()
                        }
                    }

                    onDarkModeChanged: {
                        requestPaint()
                    }

                    Component.onCompleted: {
                        if (qrData && qrData.length > 0) {
                            requestPaint()
                        }
                    }

                    onPaint: {
                        var ctx = getContext("2d")
                        ctx.clearRect(0, 0, width, height)

                        if (!qrData || qrData.length === 0) return

                        var bgColor = darkMode ? "#2A2A2A" : "#FFFFFF"
                        var fgColor = darkMode ? "#FFFFFF" : "#000000"

                        try {
                            var qr = QRCodeJS.qrcode(0, 'M')
                            qr.addData(qrData)
                            qr.make()

                            var moduleCount = qr.getModuleCount()
                            var cellSize = Math.floor(width / moduleCount)
                            var offset = Math.floor((width - cellSize * moduleCount) / 2)

                            // 背景
                            ctx.fillStyle = bgColor
                            ctx.fillRect(0, 0, width, height)

                            // 绘制模块
                            ctx.fillStyle = fgColor
                            for (var row = 0; row < moduleCount; row++) {
                                for (var col = 0; col < moduleCount; col++) {
                                    if (qr.isDark(row, col)) {
                                        ctx.fillRect(
                                            offset + col * cellSize,
                                            offset + row * cellSize,
                                            cellSize, cellSize
                                        )
                                    }
                                }
                            }
                        } catch(e) {
                            console.warn("QR code generation failed:", e)
                        }
                    }
                }
            }

            // 统计信息 2x2 网格
            GridLayout {
                Layout.fillWidth: true
                columns: 2
                rowSpacing: 8
                columnSpacing: 8

                // 邀请人数
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 68
                    radius: 10
                    color: Theme.colors.surfaceElevated

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 4

                        Label {
                            text: registeredCount.toString()
                            font.pixelSize: 16
                            font.bold: true
                            color: Theme.colors.textPrimary
                            Layout.alignment: Qt.AlignHCenter
                        }
                        Label {
                            text: qsTr("Invitees")
                            font.pixelSize: 10
                            color: isDarkMode ? "#999999" : "#888888"
                            Layout.alignment: Qt.AlignHCenter
                        }
                    }
                }

                // 佣金比例
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 68
                    radius: 10
                    color: Theme.colors.surfaceElevated

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 4

                        Label {
                            text: commissionRate + "%"
                            font.pixelSize: 16
                            font.bold: true
                            color: Theme.colors.textPrimary
                            Layout.alignment: Qt.AlignHCenter
                        }
                        Label {
                            text: qsTr("Commission Rate")
                            font.pixelSize: 10
                            color: isDarkMode ? "#999999" : "#888888"
                            Layout.alignment: Qt.AlignHCenter
                        }
                    }
                }

                // 佣金余额
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 68
                    radius: 10
                    color: Theme.colors.surfaceElevated

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 4

                        Label {
                            text: currencySymbol + (commissionBalance / currencyUnit).toFixed(2)
                            font.pixelSize: 16
                            font.bold: true
                            color: Theme.colors.success
                            Layout.alignment: Qt.AlignHCenter
                        }
                        Label {
                            text: qsTr("Commission Balance")
                            font.pixelSize: 10
                            color: isDarkMode ? "#999999" : "#888888"
                            Layout.alignment: Qt.AlignHCenter
                        }
                    }
                }

                // 累计佣金
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 68
                    radius: 10
                    color: Theme.colors.surfaceElevated

                    ColumnLayout {
                        anchors.centerIn: parent
                        spacing: 4

                        Label {
                            text: currencySymbol + (totalCommission / currencyUnit).toFixed(2)
                            font.pixelSize: 16
                            font.bold: true
                            color: Theme.colors.textPrimary
                            Layout.alignment: Qt.AlignHCenter
                        }
                        Label {
                            text: qsTr("Total Commission")
                            font.pixelSize: 10
                            color: isDarkMode ? "#999999" : "#888888"
                            Layout.alignment: Qt.AlignHCenter
                        }
                    }
                }
            }

            // 邀请明细展开按钮
            Rectangle {
                Layout.fillWidth: true
                Layout.preferredHeight: 36
                radius: Theme.radius.sm
                color: Theme.colors.surfaceElevated
                visible: registeredCount > 0

                RowLayout {
                    anchors.centerIn: parent
                    spacing: 6

                    Label {
                        text: showDetails ? qsTr("Hide Details") : qsTr("Commission Records")
                        font.pixelSize: 12
                        color: Theme.colors.primary
                    }

                    Label {
                        text: showDetails ? "\u25B2" : "\u25BC"
                        font.pixelSize: 10
                        color: Theme.colors.primary
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        showDetails = !showDetails
                        if (showDetails && inviteDetails.length === 0 && !isLoadingDetails) {
                            inviteCard.detailsRequested()
                        }
                    }
                }
            }

            // 邀请明细列表
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 6
                visible: showDetails

                // 加载中
                Label {
                    visible: isLoadingDetails
                    text: qsTr("Loading details...")
                    font.pixelSize: 12
                    color: Theme.colors.textSecondary
                    Layout.alignment: Qt.AlignHCenter
                }

                // 明细列表
                Repeater {
                    model: inviteDetails

                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 44
                        radius: 8
                        color: Theme.colors.surfaceElevated

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            spacing: 8

                            Label {
                                text: modelData.tradeNo || ""
                                font.pixelSize: 12
                                color: Theme.colors.textPrimary
                                elide: Text.ElideMiddle
                                Layout.fillWidth: true
                            }

                            Label {
                                text: modelData.createdAt || ""
                                font.pixelSize: 11
                                color: Theme.colors.textSecondary
                            }

                            Label {
                                text: "+" + currencySymbol + (modelData.getAmount / currencyUnit).toFixed(2)
                                font.pixelSize: 12
                                font.bold: true
                                color: Theme.colors.success
                            }
                        }
                    }
                }

                // 无数据提示
                Label {
                    visible: !isLoadingDetails && inviteDetails.length === 0
                    text: qsTr("No commission records yet")
                    font.pixelSize: 12
                    color: Theme.colors.textSecondary
                    Layout.alignment: Qt.AlignHCenter
                }
            }
        }
    }

    Component.onDestruction: {
        copyTooltipTimer.stop()
    }
}
