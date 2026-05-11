// Pipeline para terraform: plan + apply (con aprobación manual) o destroy.
// Cada stack tiene su propio state remoto en S3 (mrkrtmn-iac-tfstate).
// Param STACK: "shared", "bots/faitpro-bot", "bots/<otro>"...
// Param ACTION: "plan" (default, no aplica), "apply" (plan + approval + apply), "destroy" (plan -destroy + approval + destroy).

pipeline {
    agent { label 'agent-1' }

    parameters {
        choice(
            name: 'STACK',
            choices: ['shared', 'bots/faitpro-bot'],
            description: 'Stack a aplicar (carpeta dentro del repo)'
        )
        choice(
            name: 'ACTION',
            choices: ['plan', 'apply', 'destroy'],
            description: 'plan = solo muestra cambios; apply = plan + approval + apply; destroy = plan -destroy + approval + destroy'
        )
        booleanParam(
            name: 'AUTO_APPROVE',
            defaultValue: false,
            description: 'Saltea el approval manual (peligroso, usar solo para "shared" en bootstrap)'
        )
    }

    options {
        disableConcurrentBuilds()
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 30, unit: 'MINUTES')
        timestamps()
    }

    environment {
        AWS_CREDS_ID = 'aws-terraform'
        TF_IN_AUTOMATION = 'true'
        TF_INPUT         = 'false'
    }

    stages {

        stage('Validate stack path') {
            steps {
                script {
                    if (!fileExists("${params.STACK}/backend.tf")) {
                        error "Stack '${params.STACK}' no existe o le falta backend.tf"
                    }
                    echo "Stack: ${params.STACK}"
                    echo "Action: ${params.ACTION}"
                }
            }
        }

        stage('Terraform init') {
            steps {
                dir(params.STACK) {
                    withCredentials([usernamePassword(
                        credentialsId: env.AWS_CREDS_ID,
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY'
                    )]) {
                        sh 'terraform init -input=false -lockfile=readonly || terraform init -input=false'
                    }
                }
            }
        }

        stage('Terraform validate + fmt check') {
            steps {
                dir(params.STACK) {
                    sh '''
                        terraform fmt -check -recursive -diff
                        terraform validate
                    '''
                }
            }
        }

        stage('Terraform plan') {
            steps {
                dir(params.STACK) {
                    withCredentials([usernamePassword(
                        credentialsId: env.AWS_CREDS_ID,
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY'
                    )]) {
                        script {
                            def destroyFlag = params.ACTION == 'destroy' ? '-destroy' : ''
                            sh """
                                terraform plan ${destroyFlag} -out=tfplan -input=false
                                terraform show -no-color tfplan > plan.txt
                            """
                        }
                    }
                    archiveArtifacts artifacts: 'plan.txt', fingerprint: false, onlyIfSuccessful: true
                }
            }
        }

        stage('Approval') {
            when {
                allOf {
                    expression { params.ACTION in ['apply', 'destroy'] }
                    expression { !params.AUTO_APPROVE }
                }
            }
            steps {
                script {
                    def planSummary = readFile("${params.STACK}/plan.txt")
                    def lines = planSummary.readLines()
                    def tail = lines.size() > 80 ? lines[-80..-1].join('\n') : planSummary
                    input message: "Aplicar ${params.ACTION} a ${params.STACK}?",
                          parameters: [text(name: 'plan_tail', defaultValue: tail, description: 'Últimas 80 líneas del plan')]
                }
            }
        }

        stage('Terraform apply / destroy') {
            when { expression { params.ACTION in ['apply', 'destroy'] } }
            steps {
                dir(params.STACK) {
                    withCredentials([usernamePassword(
                        credentialsId: env.AWS_CREDS_ID,
                        usernameVariable: 'AWS_ACCESS_KEY_ID',
                        passwordVariable: 'AWS_SECRET_ACCESS_KEY'
                    )]) {
                        sh 'terraform apply -input=false tfplan'
                    }
                }
            }
        }
    }

    post {
        success {
            echo "${params.ACTION} de ${params.STACK} completado"
        }
        failure {
            echo "${params.ACTION} de ${params.STACK} fallido"
        }
        always {
            dir(params.STACK) {
                sh 'rm -f tfplan plan.txt || true'
            }
            cleanWs()
        }
    }
}
