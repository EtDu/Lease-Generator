const subscribe = async (contract) => {
    return new Promise(resolve => {
        web3.eth.subscribe('logs', {
            address: contract.address,
        }, (error) => {
            if (!error) {
                // const eventObj = web3.eth.abi.decodeLog(
                //     eventJsonInterface,
                //     result.data,
                //     result.topics.slice(1)
                // )
                // console.log(`New ${eventName}!`, eventObj)
                resolve()
            } else {
                console.log(error)
            }
        })
    })
}
module.exports = subscribe;