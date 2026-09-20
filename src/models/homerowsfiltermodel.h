#pragma once

#include <QJSValue>
#include <QSortFilterProxyModel>
#include <QtQml/qqmlregistration.h>

//! 首页行过滤代理:pageList 恒定绑它,永不切换模型对象。
//! 过滤谓词是 QML JS 回调(libMatch,FuzzyMatch 留在 QML,单一真相源);
//! 空查询时谓词恒真 = 透传,源模型原位更新经代理正常转发(零委托重建)。
//! 历史:旧实现按查询空否在 C++ 模型 ↔ JS 快照间切换 model,切换瞬间
//! DelegateModel 读已释放对象概率性崩溃(10 轮复现矩阵实证);恒定模型
//! 后该崩溃面整个消失。
class HomeRowsFilterModel : public QSortFilterProxyModel
{
    Q_OBJECT
    QML_ELEMENT
    //! JS 谓词:function(rowMap) -> bool;不可调用 = 不过滤。
    Q_PROPERTY(QJSValue filterPredicate WRITE setFilterPredicate)
    //! 双源切换:customActive 时源切到 customSource(自定义聚合行)。
    //! C++ 侧 setSourceModel 安全(历史崩溃面在 QML 侧 JS 数组/C++ 模型
    //! 异质切换);切换即重建委托——仅发生在模式/过滤态切换,非常态路径。
    Q_PROPERTY(QAbstractItemModel* plainSource WRITE setPlainSource)
    Q_PROPERTY(QAbstractItemModel* customSource WRITE setCustomSource)
    Q_PROPERTY(bool customActive WRITE setCustomActive NOTIFY customActiveChanged)

public:
    explicit HomeRowsFilterModel(QObject *parent = nullptr);

    void setFilterPredicate(const QJSValue &fn);
    void setPlainSource(QAbstractItemModel *m);
    void setCustomSource(QAbstractItemModel *m);
    void setCustomActive(bool b);

    //! 查询词变化后调用(谓词闭包捕获查询词,此处仅触发重过滤)。
    Q_INVOKABLE void refilter();

protected:
    bool filterAcceptsRow(int sourceRow, const QModelIndex &sourceParent) const override;

signals:
    void customActiveChanged();

private:
    void applySource();

    mutable QJSValue m_pred;
    QAbstractItemModel *m_plain = nullptr;
    QAbstractItemModel *m_custom = nullptr;
    bool m_customActive = false;
};
