class BaseSpecificException(Exception):
    pass

class GetSecretException(BaseSpecificException):
    def __init__(self, message):
        super().__init__(message)

class GetGlobalCertificatesException(BaseSpecificException):
    def __init__(self, message):
        super().__init__(message)

class GetSQLScriptException(BaseSpecificException):
    def __init__(self, message):
        super().__init__(message)

class ExecuteSQLScriptException(BaseSpecificException):
    def __init__(self, message):
        super().__init__(message)