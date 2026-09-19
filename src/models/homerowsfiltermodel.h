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

public:
    explicit HomeRowsFilterModel(QObject *parent = nullptr);

    void setFilterPredicate(const QJSValue &fn);

    //! 查询词变化后调用(谓词闭包捕获查询词,此处仅触发重过滤)。
    Q_INVOKABLE void refilter();

protected:
    bool filterAcceptsRow(int sourceRow, const QModelIndex &sourceParent) const override;

private:
    mutable QJSValue m_pred;
};
