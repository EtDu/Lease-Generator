const timer = async () => {
    return new Promise(resolve => {
        setTimeout(() => {
            resolve()
        }, 3000);
    })
}
module.exports = timer;